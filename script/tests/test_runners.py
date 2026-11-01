import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]


class RunnerArgumentsTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.script = self.root / "script"
        self.script.mkdir()
        (self.script / "tests").mkdir()
        for name in ("test.sh", "build_and_run.sh"):
            shutil.copy2(SCRIPTS / name, self.script / name)
        checker = self.script / "check_structure.sh"
        checker.write_text("#!/bin/bash\nexit 0\n")
        checker.chmod(0o755)
        commands = self.root / "bin"
        commands.mkdir()
        self.calls = self.root / "calls"
        self.arguments = self.root / "arguments"
        self.lane = self.root / "lane"
        for name in ("xcodebuild", "pkill", "rm", "mkdir"):
            command = commands / name
            body = '#!/bin/bash\nprintf "%s\\n" "$0" >> "$CALLS"\n'
            if name == "xcodebuild":
                body += ('printf "__CALL__\\n" >> "$ARGUMENTS"\n'
                         'printf "%s\\n" "$@" >> "$ARGUMENTS"\n'
                         'printf "%s:%s\\n" "$TEST_RUNNER_LATEST_UI_TESTS" "$LATEST_UI_TESTS" >> "$LANE"\n')
            command.write_text(body)
            command.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(commands) + ":" + os.environ["PATH"],
                                CALLS=str(self.calls), ARGUMENTS=str(self.arguments),
                                LANE=str(self.lane), LATEST_UI_TESTS="1")

    def run_script(self, name, *arguments):
        return subprocess.run([str(self.script / name), *arguments], env=self.environment,
                              capture_output=True, text=True, timeout=5)

    def test_build_help_and_invalid_arguments_have_no_side_effects(self):
        for arguments, status in ((["--help"], 0), (["typo"], 2),
                                  (["run", "--unknown"], 2), (["run", "--signed", "extra"], 2)):
            with self.subTest(arguments=arguments):
                result = self.run_script("build_and_run.sh", *arguments)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertFalse(self.calls.exists(), "Validation must precede build/kill/delete")

    def invocations(self):
        return [call.splitlines() for call in self.arguments.read_text().split("__CALL__\n")[1:]]

    def test_default_uses_only_the_unhosted_scheme(self):
        result = self.run_script("test.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.invocations()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][calls[0].index("-scheme") + 1], "Latest Unit Tests")
        self.assertNotIn("-testPlan", calls[0])
        self.assertEqual(self.lane.read_text().strip(), "0:0")

    def test_hosted_plans_and_filters_are_preserved(self):
        for mode, plan, environment in (("--integration", "LatestIntegration", "0:0"),
                                        ("--ui", "LatestUI", "1:1")):
            with self.subTest(mode=mode):
                self.arguments.unlink(missing_ok=True)
                self.lane.unlink(missing_ok=True)
                filters = ["-skip-testing:Latest Tests/Example", "-only-testing:Latest Tests/Selected"]
                result = self.run_script("test.sh", mode, *filters)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.invocations()
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0][calls[0].index("-scheme") + 1], "Latest")
                self.assertEqual(calls[0][calls[0].index("-testPlan") + 1], plan)
                for argument in filters:
                    self.assertIn(argument, calls[0])
                self.assertEqual(self.lane.read_text().strip(), environment)

    def test_all_runs_three_lanes_sequentially_with_distinct_result_bundles(self):
        result = self.run_script("test.sh", "--all", "--coverage")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.invocations()
        self.assertEqual(len(calls), 3)
        self.assertEqual([call[call.index("-scheme") + 1] for call in calls],
                         ["Latest Unit Tests", "Latest", "Latest"])
        self.assertEqual([call[call.index("-testPlan") + 1] for call in calls[1:]],
                         ["LatestIntegration", "LatestUI"])
        bundles = [call[call.index("-resultBundlePath") + 1] for call in calls]
        self.assertEqual(len(set(bundles)), 3)
        self.assertEqual(self.lane.read_text().splitlines(), ["0:0", "0:0", "1:1"])
        for call in calls:
            self.assertEqual(call[call.index("-enableCodeCoverage") + 1], "YES")

    def test_all_routes_unit_selection_without_launching_a_hosted_lane(self):
        selection = "-only-testing:Latest Unit Tests/VersionParserTest"
        result = self.run_script("test.sh", "--all", selection)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.invocations()
        self.assertEqual(len(calls), 1)
        self.assertIn(selection, calls[0])
        self.assertEqual(calls[0][calls[0].index("-scheme") + 1], "Latest Unit Tests")
        self.assertEqual(self.lane.read_text().strip(), "0:0")

    def test_incompatible_or_unknown_target_selection_fails_before_commands(self):
        for arguments in (("-only-testing:Latest Tests/Example",),
                          ("-skip-testing:Latest Tests/Example",),
                          ("--ui", "-only-testing:Latest Unit Tests/Example"),
                          ("-only-testing:Unknown/Example",)):
            with self.subTest(arguments=arguments):
                result = self.run_script("test.sh", *arguments)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.calls.exists(), "Lane validation must precede any commands")


if __name__ == "__main__":
    unittest.main()
