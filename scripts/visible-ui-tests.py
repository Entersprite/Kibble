#!/usr/bin/env python3
"""Discover and run explicitly opted-in desktop tests sequentially."""
import fcntl
import os
from pathlib import Path
import re
import subprocess
import sys


ENVIRONMENT_KEY = "KIBBLE_VISIBLE_UI_TESTS"
LOCK_DIRECTORY = Path("/tmp")
SUITE = re.compile(
    r"@Suite\(\s*\.enabled\(if:\s*visibleUITestsEnabled\)[\s\S]*?\)"
    r"\s*(?:struct|class)\s+(\w+)"
)
TEST = re.compile(
    r"@Test\(\.enabled\(if:\s*visibleUITestsEnabled\)\)\s+func\s+(\w+)"
)
PRESENTATION = re.compile(
    r"\.(?:orderFront|orderFrontRegardless|makeKeyAndOrderFront|runModal|popUp)\s*\("
)


def discover(root):
    """The opt-in traits are the registry; there is no second skip list."""
    groups = {}
    quiet_sources = []
    visible_suites = set()
    for source in sorted((root / "Packages").glob("*/Tests/**/*.swift")):
        text = source.read_text()
        suites = SUITE.findall(text)
        tests = TEST.findall(text)
        if text.count("if: visibleUITestsEnabled") != len(suites) + len(tests):
            raise ValueError(f"{source}: unrecognized visible UI opt-in trait")
        if PRESENTATION.search(text) and not suites and not tests:
            raise ValueError(f"{source}: desktop presentation needs a visible UI opt-in")
        if not suites and not tests:
            quiet_sources.append((source, text))
            continue
        visible_suites.update(suites)
        package = source.relative_to(root).parts[1]
        patterns = groups.setdefault(package, [])
        patterns.extend(r"(?:^|[./])" + name + r"(?:[./]|$)" for name in suites)
        # Individual opt-ins live in their file's same-named test suite.
        if tests and not re.search(r"\bstruct\s+" + source.stem + r"\b", text):
            raise ValueError(f"{source}: individual UI tests need a same-named suite")
        patterns.extend(
            r"(?:^|[./])" + source.stem + "/" + name + r"(?:\(|$)" for name in tests
        )
    if not groups:
        raise ValueError("No visible UI tests found; refusing an empty UI pass")
    # A suite trait does not protect callers of a helper nested in that suite.
    for source, text in quiet_sources:
        for suite in visible_suites:
            if re.search(r"\b" + suite + r"\s*\.", text):
                raise ValueError(f"{source}: reuses visible {suite}; add a visible UI opt-in")
    return groups


def run(root, arguments):
    # Selection and parallelism belong to this runner. In particular, SwiftPM
    # combines multiple --filter arguments with OR, which could run quiet tests.
    forbidden = (
        "--filter", "--skip", "--parallel", "--num-workers", "--list-tests", "-l", "--help", "-h"
    )
    for argument in arguments:
        if argument.split("=", 1)[0] in forbidden or argument in ("list", "--disable-swift-testing"):
            raise ValueError(f"{argument} is not supported by the visible UI runner")
    groups = discover(root)
    environment = dict(os.environ, **{ENVIRONMENT_KEY: "1"})
    # A per-user lock outside any checkout also covers independent worktrees.
    # Never unlink a lock file: a waiter may already hold its inode open.
    lock_path = LOCK_DIRECTORY / f"kibble-visible-ui-{os.getuid()}.lock"
    with lock_path.open("a") as lock:
        print(f"Visible UI tests: waiting for desktop lock ({lock_path})", flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
        print("Visible UI tests: desktop windows may appear; suites run sequentially.", flush=True)
        failed = False
        for package, patterns in groups.items():
            directory = root / "Packages" / package
            result = subprocess.run(
                ["swift", "build", "--build-tests", "--force-resolved-versions"],
                cwd=directory, env=environment, pass_fds=(lock.fileno(),)
            )
            if result.returncode:
                failed = True
                continue
            listing = subprocess.run(
                ["swift", "test", "--skip-build", "list"], cwd=directory,
                env=environment, capture_output=True, text=True, pass_fds=(lock.fileno(),)
            )
            if listing.returncode:
                print(listing.stderr, file=sys.stderr)
                failed = True
                continue
            missing = [pattern for pattern in patterns if not any(
                re.search(pattern, line) for line in listing.stdout.splitlines()
            )]
            if missing:
                print(f"No compiled UI tests match {package}: {missing}", file=sys.stderr)
                failed = True
                continue
            # Preserve the package's common AppKit process while disabling
            # parallel test execution. A separate process per suite loses that
            # native context and is unnecessary for desktop serialization.
            selection = "|".join(f"(?:{pattern})" for pattern in patterns)
            result = subprocess.run(
                ["swift", "test", "--skip-build", *arguments, "--no-parallel", "--filter", selection],
                cwd=directory, env=environment, pass_fds=(lock.fileno(),)
            )
            failed |= result.returncode != 0
        print("Visible UI checks failed" if failed else "Visible UI checks passed", flush=True)
        return int(failed)


def main():
    root = Path(__file__).resolve().parents[1]
    try:
        if sys.argv[1:] == ["--check"]:
            groups = discover(root)
            print(f"{sum(map(len, groups.values()))} visible UI selections in {len(groups)} packages")
            return 0
        return run(root, sys.argv[1:])
    except (OSError, ValueError) as error:
        print(f"Visible UI tests: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
