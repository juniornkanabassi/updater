import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "lint.sh"


class LintRunnerTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "script").mkdir()
        self.script = self.root / "script/lint.sh"
        shutil.copy2(SCRIPT, self.script)
        self.calls = self.root / "calls"
        self.build_arguments = self.root / "build-arguments"
        self.tool = self.root / "build/tools/swiftlint-0.65.1/swiftlint"
        self.tool.parent.mkdir(parents=True)
        self.write_command(self.tool, '''
if [[ "$1" == version ]]; then echo 0.65.1; exit 0; fi
printf '%s\\n' "$@" >> "$LINT_TEST_CALLS"
printf '%s\\n' "${LINT_TEST_OUTPUT:-}"
exit "${LINT_TEST_EXIT:-0}"
''')
        commands = self.root / "bin"
        commands.mkdir()
        self.write_command(commands / "xcodebuild", '''
printf '__CALL__\\n' >> "$LINT_TEST_BUILD_ARGUMENTS"
printf '%s\\n' "$@" >> "$LINT_TEST_BUILD_ARGUMENTS"
exit "${LINT_TEST_BUILD_EXIT:-0}"
''')
        self.write_command(commands / "curl", '''
echo download >> "$LINT_TEST_CALLS"
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == --output ]]; then printf 'untrusted archive' > "$2"; exit 0; fi
  shift
done
exit 1
''')
        self.write_command(commands / "unzip", 'echo unzip >> "$LINT_TEST_CALLS"\n')
        self.environment = dict(os.environ, PATH=str(commands) + ":" + os.environ["PATH"],
                                LINT_TEST_CALLS=str(self.calls),
                                LINT_TEST_BUILD_ARGUMENTS=str(self.build_arguments))

    @staticmethod
    def write_command(path, body):
        path.write_text("#!/bin/bash\nset -eu\n" + body)
        path.chmod(0o755)

    def run_script(self, *arguments, **environment):
        return subprocess.run([str(self.script), *arguments],
                              env=dict(self.environment, **environment),
                              capture_output=True, text=True, timeout=5)

    def test_argument_validation_has_no_download_or_build_side_effects(self):
        self.tool.unlink()
        for arguments, status in ((["--help"], 0), (["typo"], 2),
                                  (["--analyze", "extra"], 2)):
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertFalse(self.calls.exists())
                self.assertFalse(self.build_arguments.exists())

    def test_lint_is_strict_and_preserves_failure(self):
        result = self.run_script(LINT_TEST_EXIT="2")
        self.assertEqual(result.returncode, 2, result.stderr)
        arguments = self.calls.read_text().splitlines()
        self.assertEqual(arguments[0], "lint")
        self.assertIn("--strict", arguments)
        self.assertFalse(self.build_arguments.exists())

    def test_analysis_compiles_audit_callers_without_running_tests(self):
        result = self.run_script("--analyze", LINT_TEST_OUTPUT="warning: runtime callback")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [call.splitlines() for call in self.build_arguments.read_text().split("__CALL__\n")[1:]]
        self.assertEqual([call[call.index("-scheme") + 1] for call in calls],
                         ["Latest", "Latest Unit Tests"])
        for index, arguments in enumerate(calls):
            self.assertIn("clean", arguments)
            self.assertIn("build-for-testing", arguments)
            self.assertNotIn("test", arguments)
            self.assertIn("CODE_SIGNING_ALLOWED=NO", arguments)
            self.assertIn("OTHER_SWIFT_FLAGS=$(inherited) -DLATEST_RELEASE_NOTES_AUDIT", arguments)
            product_root = "LintDerivedData" if index == 0 else "LintUnitDerivedData"
            self.assertIn(str(self.root / "build" / product_root), arguments)
        analyzer_arguments = self.calls.read_text().splitlines()
        self.assertEqual(analyzer_arguments[0], "analyze")
        self.assertNotIn("--strict", analyzer_arguments)

    def test_analysis_rejects_failed_build_and_sourcekit_false_success(self):
        result = self.run_script("--analyze", LINT_TEST_BUILD_EXIT="65")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(self.calls.exists(), "Do not analyze an incomplete compiler log")
        result = self.run_script("--analyze", LINT_TEST_OUTPUT="fixture.swift:48:27: error: circular reference")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Declaration analysis failed", result.stderr)

    def test_bootstrap_rejects_archive_with_wrong_checksum(self):
        self.tool.unlink()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls.read_text().splitlines(), ["download"])
        self.assertFalse(self.tool.exists())


if __name__ == "__main__":
    unittest.main()
