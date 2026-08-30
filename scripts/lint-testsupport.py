#!/usr/bin/env python3
"""Assert that test scaffolding cannot reach shipping code.

Reads SwiftPM's own package graph (`swift package dump-package`) rather than
regexing Package.swift: source text cannot distinguish a target's DECLARATION
from a DEPENDENCY on it, and a lint that cries wolf gets switched off - which
is the same outcome as having no lint at all.

Rule: a target whose name ends in "TestSupport" is scaffolding. It must never
be exposed as a product (an app could link it) and must never be depended on
by a non-test target (it would ship).

Usage: swift package dump-package | lint-testsupport.py <package-dir>
Exit:  0 clean, 1 violations found (printed to stdout), 2 unusable input.
"""
import json
import sys


def main() -> int:
    where = sys.argv[1] if len(sys.argv) > 1 else "<stdin>"
    try:
        pkg = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError) as exc:
        print("{}: could not parse package graph: {}".format(where, exc))
        return 2

    targets = pkg.get("targets", [])
    support = {t["name"] for t in targets if t["name"].endswith("TestSupport")}
    if not support:
        return 0

    violations = []

    for product in pkg.get("products", []):
        for target in product.get("targets", []):
            if target in support:
                violations.append(
                    "{}: product '{}' exposes test-support target '{}'".format(
                        where, product["name"], target
                    )
                )

    for target in targets:
        if target.get("type") == "test":
            continue
        for dependency in target.get("dependencies", []):
            # A dependency is {"byName": [...]}, {"target": [...]},
            # or {"product": [name, package, ...]}. Only the first element
            # of each list is a name; the rest is metadata.
            for names in dependency.values():
                if not isinstance(names, list) or not names:
                    continue
                first = names[0]
                if isinstance(first, str) and first in support:
                    violations.append(
                        "{}: non-test target '{}' depends on '{}'".format(
                            where, target["name"], first
                        )
                    )

    for line in violations:
        print(line)
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
