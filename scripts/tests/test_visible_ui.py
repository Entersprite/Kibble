import importlib.util
import fcntl
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "visible_ui", Path(__file__).resolve().parents[1] / "visible-ui-tests.py"
)
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)


class VisibleUITests(unittest.TestCase):
    def source(self, root, text):
        path = root / "Packages/Example/Tests/ExampleTests/DesktopTests.swift"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def test_new_ungated_presentation_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.source(root, "struct DesktopTests { func check() { window.orderFront(nil) } }")
            with self.assertRaisesRegex(ValueError, "needs a visible UI opt-in"):
                UI.discover(root)

    def test_suite_and_individual_selection_do_not_include_neighboring_quiet_tests(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.source(root, """
                @Suite(.enabled(if: visibleUITestsEnabled), .serialized)
                struct SheetTests {}
                struct DesktopTests {
                    @Test(.enabled(if: visibleUITestsEnabled)) func opensPanel() {}
                    @Test func quietPolicy() {}
                }
            """)
            patterns = UI.discover(root)["Example"]
            selected = lambda name: any(re.search(pattern, name) for pattern in patterns)
            self.assertTrue(selected("ExampleTests.SheetTests/returnSaves()"))
            self.assertTrue(selected("ExampleTests.DesktopTests/opensPanel()"))
            self.assertFalse(selected("ExampleTests.DesktopTests/quietPolicy()"))
            self.assertFalse(selected("ExampleTests.OtherSheetTests/returnSaves()"))

    def test_empty_or_unrecognized_registry_fails_instead_of_claiming_coverage(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaises(ValueError):
                UI.discover(root)
            self.source(root, "@Test(.enabled(if: visibleUITestsEnabled), .serialized) func panel() {}")
            with self.assertRaisesRegex(ValueError, "unrecognized"):
                UI.discover(root)

    def test_reusing_a_window_opening_helper_also_requires_an_opt_in(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.source(root, "@Suite(.enabled(if: visibleUITestsEnabled)) struct DesktopTests {}")
            helper = root / "Packages/Example/Tests/ExampleTests/QuietTests.swift"
            helper.write_text("struct QuietTests { func check() { DesktopTests.Harness() } }")
            with self.assertRaisesRegex(ValueError, "reuses visible"):
                UI.discover(root)

    def test_execution_is_opted_in_serial_and_failures_survive_later_success(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.source(root, """
                @Suite(.enabled(if: visibleUITestsEnabled)) struct SheetTests {}
            """)
            other = root / "Packages/Other/Tests/OtherTests/PanelTests.swift"
            other.parent.mkdir(parents=True)
            other.write_text("@Suite(.enabled(if: visibleUITestsEnabled)) struct PanelTests {}")
            calls = []

            def swift(command, **kwargs):
                self.assertEqual(kwargs["env"][UI.ENVIRONMENT_KEY], "1")
                self.assertTrue(kwargs["pass_fds"])
                lock_path = root / f"kibble-visible-ui-{os.getuid()}.lock"
                with lock_path.open("a") as contender:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                calls.append(command)
                if command[-1] == "list":
                    return subprocess.CompletedProcess(command, 0,
                        stdout="ExampleTests.SheetTests/check()\nExampleTests.PanelTests/check()", stderr="")
                return subprocess.CompletedProcess(command, int("SheetTests" in command[-1]))

            with patch.object(UI.subprocess, "run", side_effect=swift), \
                    patch.object(UI, "LOCK_DIRECTORY", root), \
                    patch("builtins.print"):
                self.assertEqual(UI.run(root, []), 1)
            tests = [command for command in calls if "--filter" in command]
            self.assertEqual(len(tests), 2)
            self.assertTrue(all("--no-parallel" in command for command in tests))

    def test_missing_compiled_tests_and_unsafe_selection_arguments_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.source(root, "@Suite(.enabled(if: visibleUITestsEnabled)) struct MissingTests {}")
            with patch.object(UI.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, stdout="ExampleTests.OtherTests/check()", stderr=""
            )) as swift, patch.object(UI, "LOCK_DIRECTORY", root), \
                    patch("builtins.print"):
                self.assertEqual(UI.run(root, []), 1)
                self.assertEqual(swift.call_count, 2)
            for argument in ["--filter=OtherTests", "--skip", "--parallel", "--help"]:
                with self.subTest(argument=argument), self.assertRaises(ValueError):
                    UI.run(root, [argument])

    def test_quiet_mode_overrides_inherited_ui_opt_in(self):
        script = Path(__file__).resolve().parents[1] / "test.sh"
        # Exercise the actual mode parser, stopping before the package scans.
        prefix = script.read_text().split("fail=0", 1)[0]
        result = subprocess.run(
            ["bash", "-c", prefix + '\nprintf "MODE=%s" "$KIBBLE_VISIBLE_UI_TESTS"', str(script)],
            env=dict(os.environ, **{UI.ENVIRONMENT_KEY: "1"}), capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MODE=0", result.stdout)

    def test_all_mode_runs_both_passes_and_propagates_either_failure_from_any_directory(self):
        script = Path(__file__).resolve().parents[1] / "test.sh"
        prefix = script.read_text().split("fail=0", 1)[0]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            scripts = root / "scripts"
            scripts.mkdir()
            runner = scripts / "test.sh"
            runner.write_text(prefix + '\nexit "${QUIET_RESULT:-0}"\n')
            runner.chmod(0o755)
            (scripts / "visible-ui-tests.py").write_text(
                'import os\nprint("VISIBLE-PASS")\nraise SystemExit(int(os.environ["UI_RESULT"]))\n'
            )
            elsewhere = root / "other"
            elsewhere.mkdir()
            for quiet, visible in [(0, 0), (1, 0), (0, 1)]:
                result = subprocess.run(
                    ["../scripts/test.sh", "--all"], cwd=elsewhere,
                    env=dict(os.environ, QUIET_RESULT=str(quiet), UI_RESULT=str(visible)),
                    capture_output=True, text=True
                )
                self.assertEqual(result.returncode, int(bool(quiet or visible)), result.stderr)
                self.assertIn("Quiet checks:", result.stdout)
                self.assertIn("VISIBLE-PASS", result.stdout)
                self.assertEqual("all quiet and visible UI checks passed" in result.stdout,
                                 quiet == visible == 0)


if __name__ == "__main__":
    unittest.main()
