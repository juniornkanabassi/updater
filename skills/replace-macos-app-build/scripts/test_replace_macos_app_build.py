"""Installer regressions with isolated bundles and controlled macOS services."""

import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).parent
TOOLS = r'''
import json, os, plistlib, subprocess, sys
from pathlib import Path
state_path = Path(os.environ['INSTALLER_TEST_STATE'])
state = json.loads(state_path.read_text())
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with Path(os.environ['INSTALLER_TEST_CALLS']).open('a') as file:
    file.write(json.dumps([name, *args]) + '\n')
if state.get('fail_tool') == name:
    print('injected service failure', file=sys.stderr)
    sys.exit(1)
installed = Path(state['installed'])
if name == 'lsregister':
    if '-dump' in args:
        for path in state.get('registered', []):
            p = Path(path)
            if p.exists():
                info = plistlib.loads((p/'Contents/Info.plist').read_bytes())
                print('---------------------------------------------------------------------------------')
                print('path:                       ' + path + ' (0x1234)')
                print('name:                       ' + p.stem)
                print('localizedNames:             "en" = "Sample"')
                print('identifier:                 ' + info['CFBundleIdentifier'])
    elif '-u' in args:
        state['registered'] = [p for p in state.get('registered', []) if p != args[-1]]
elif name == 'mdfind':
    paths = state.get('indexed', []) + [str(installed)]
    if state.get('empty_index'):
        paths = []
    for path in dict.fromkeys(paths):
        if Path(path).exists() or state.get('stale_index'):
            sys.stdout.buffer.write(os.fsencode(path) + b'\0')
elif name == 'osascript':
    if '-l' in args:
        print(json.dumps(state.get('running', [])))
    elif 'path to app' in args[-1]:
        print(state.get('resolved', str(installed)) + '/')
    elif 'to quit' not in args[-1]:
        print('false')
elif name == 'open' and not state.get('no_start'):
    executable = installed/'Contents/MacOS/Sample'
    state['running'] = [dict(path=str(installed), executable=state.get('executable', str(executable)),
                            finished=not state.get('unfinished', False))]
elif name == 'rsync':
    result = subprocess.run(['/usr/bin/rsync', *args])
    if result.returncode:
        sys.exit(result.returncode)
    if state.get('corrupt_copy') and '--dry-run' not in args:
        (installed/'Contents/MacOS/Sample.debug.dylib').write_text('damaged copy')
state_path.write_text(json.dumps(state))
'''


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="replace-skill-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.apps = self.root / "Applications"
        self.output = self.root / "home/Library/Developer/Xcode/DerivedData"
        self.bins = self.root / "bin"
        self.fixture = self.root / "skill"
        for path in (self.repo, self.apps, self.bins, self.fixture):
            path.mkdir(parents=True)
        self.installed = self.apps / "Sample.app"
        self.source = self.repo / "build/DerivedData/Build/Products/Release/Sample.app"
        self.state_file = self.root / "state.json"
        self.calls_file = self.root / "calls.jsonl"
        self.state_file.write_text(json.dumps(dict(installed=str(self.installed))))
        for name in ("xcodebuild", "osascript", "mdfind", "mdimport", "open", "killall", "lsregister", "rsync"):
            path = self.bins / name
            path.write_text(f"#!{sys.executable}\n" + TOOLS)
            path.chmod(0o755)
        # Isolate platform-owned paths without test-only production options.
        original = Path(os.environ.get("INSTALLER_UNDER_TEST", SCRIPTS / "replace_macos_app_build.sh")).read_text()
        original = original.replace('INSTALLED_APP="/Applications/$INSTALL_NAME.app"',
                                    f'INSTALLED_APP="{self.apps}/$INSTALL_NAME.app"')
        original = original.replace('"$HOME/Library/Developer/Xcode/DerivedData"', f'"{self.output}"')
        original = original.replace("Path.home() / 'Library/Developer/Xcode/DerivedData'", f"Path({str(self.output)!r})")
        original = re.sub(r"^LSREGISTER=.*$", f'LSREGISTER="{self.bins / "lsregister"}"', original, flags=re.M)
        (self.fixture / "installer.sh").write_text(original)
        helper = (SCRIPTS / "app_inventory.py").read_text()
        helper = re.sub(r"^LSREGISTER = .*$", f"LSREGISTER = {str(self.bins / 'lsregister')!r}", helper, flags=re.M)
        helper = re.sub(r"^XCODE_OUTPUT = .*$", f"XCODE_OUTPUT = Path({str(self.output)!r})", helper, flags=re.M)
        (self.fixture / "app_inventory.py").write_text(helper)
        self.env = dict(os.environ, PATH=str(self.bins) + ":" + os.environ["PATH"],
                        INSTALLER_TEST_STATE=str(self.state_file), INSTALLER_TEST_CALLS=str(self.calls_file))

    def state(self, **updates):
        value = json.loads(self.state_file.read_text())
        value.update(updates)
        self.state_file.write_text(json.dumps(value))

    def bundle(self, path, identity="test.sample", code="implementation", localized=None):
        (path / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
        info = dict(CFBundleIdentifier=identity, CFBundleShortVersionString="1.2", CFBundleVersion="3",
                    CFBundleExecutable="Sample", CFBundleName=path.stem)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        (path / "Contents/MacOS/Sample").write_text("launcher")
        (path / "Contents/MacOS/Sample.debug.dylib").write_text(code)
        if localized:
            resources = path / "Contents/Resources/en.lproj"
            resources.mkdir(parents=True)
            (resources / "InfoPlist.strings").write_text(f'"CFBundleDisplayName" = "{localized}";', encoding="utf-16")

    def run_installer(self, *options):
        return subprocess.run(["bash", str(self.fixture / "installer.sh"), "--project", "Sample.xcodeproj",
                               "--scheme", "Sample", "--app-name", "Sample", "--bundle-id", "test.sample", *options],
                              cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=60)

    def succeeds(self, *options):
        result = self.run_installer(*options)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def fails(self, *options, reason):
        result = self.run_installer(*options)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(reason, result.stdout + result.stderr)
        return result

    def test_dry_run_lists_real_candidates_without_building_or_deleting(self):
        stale = self.repo / "build/Old/Renamed.app"
        self.bundle(stale)
        result = self.succeeds("--dry-run")
        self.assertIn(str(stale), result.stdout)
        self.assertTrue(stale.exists())
        self.assertFalse(self.installed.exists())
        calls = self.calls_file.read_text()
        self.assertNotIn('"xcodebuild"', calls)
        self.assertNotIn('"-u"', calls)

    def test_complete_copy_then_remove_renamed_and_fresh_products(self):
        self.bundle(self.source)
        stale = self.repo / "build/Old/Unexpected Product.app"
        self.bundle(stale)
        unrelated = self.repo / "build/Other/Another.app"
        self.bundle(unrelated, "test.unrelated")
        self.succeeds("--open")
        self.assertFalse(self.source.exists())
        self.assertFalse(stale.exists())
        self.assertTrue(unrelated.exists())
        self.assertEqual((self.installed / "Contents/MacOS/Sample.debug.dylib").read_text(), "implementation")

    def test_identity_build_and_copy_failures_preserve_recovery_source(self):
        for failure in ("identity", "xcodebuild", "copy"):
            with self.subTest(failure=failure):
                self.bundle(self.source)
                self.state(fail_tool="xcodebuild" if failure == "xcodebuild" else "", corrupt_copy=failure == "copy")
                reason = {"identity": "does not match", "xcodebuild": "injected service failure", "copy": "differs from the build"}[failure]
                self.fails(*(["--bundle-id", "wrong.identity"] if failure == "identity" else []), reason=reason)
                self.assertTrue(self.source.exists())

    def test_other_installed_identity_is_never_overwritten(self):
        self.bundle(self.source)
        self.bundle(self.installed, "test.other", code="original")
        self.fails(reason="Refusing to overwrite")
        self.assertTrue(self.source.exists())
        self.assertEqual((self.installed / "Contents/MacOS/Sample.debug.dylib").read_text(), "original")

    def test_variant_with_localized_production_name_requires_explicit_identity(self):
        self.bundle(self.source)
        variant = self.repo / "build/Preview/Experimental.app"
        self.bundle(variant, "test.preview", localized="Sample")
        self.state(indexed=[str(variant)], registered=[str(variant)])
        self.fails(reason="Duplicate/index verification incomplete")
        self.assertTrue(variant.exists())
        self.bundle(self.source)
        self.succeeds("--cleanup-bundle-id", "test.preview")
        self.assertFalse(variant.exists())

    def test_worktree_builds_are_discovered_but_need_explicit_cleanup_root(self):
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "-q", "--allow-empty", "-m", "fixture"], check=True)
        worktree = self.root / "another worktree"
        subprocess.run(["git", "-C", str(self.repo), "worktree", "add", "--detach", "-q", str(worktree)], check=True)
        stale = worktree / "build/Products/Old.app"
        self.bundle(stale)
        self.bundle(self.source)
        marker = worktree / "Source.swift"
        marker.write_text("keep source")
        result = self.fails(reason="outside cleanup roots")
        self.assertIn(str(stale), result.stdout)
        self.assertTrue(stale.exists())
        self.bundle(self.source)
        self.succeeds("--cleanup-root", str(worktree / "build"))
        self.assertFalse(stale.exists())
        self.assertEqual(marker.read_text(), "keep source")

    def test_explicit_retention_keeps_build_and_reviewed_baseline(self):
        self.bundle(self.source)
        baseline = self.repo / "build/Baseline/Reference.app"
        self.bundle(baseline)
        self.succeeds("--keep-build", "--preserve-app", str(baseline))
        self.assertTrue(self.source.exists())
        self.assertTrue(baseline.exists())

    def test_discovery_errors_stop_before_replacement(self):
        self.bundle(self.source)
        for name in ("mdfind", "lsregister"):
            with self.subTest(tool=name):
                self.state(fail_tool=name)
                self.fails(reason="Discovery/verification failed")
                self.assertTrue(self.source.exists())
                self.assertFalse(self.installed.exists())
        self.state(fail_tool="")
        blocked = self.repo / "build/not-a-directory"
        blocked.write_text("bad output root")
        self.fails("--cleanup-root", str(blocked), reason="not a directory")
        self.assertTrue(self.source.exists())
        self.assertFalse(self.installed.exists())

    def test_wrong_launch_resolution_or_executable_fails_verification(self):
        for failure in ("resolution", "executable"):
            with self.subTest(failure=failure):
                self.bundle(self.source)
                self.state(resolved=str(self.root / "wrong.app") if failure == "resolution" else str(self.installed),
                           executable=str(self.root / "wrong-executable") if failure == "executable" else str(self.installed / "Contents/MacOS/Sample"))
                self.fails("--open", reason="resolved to" if failure == "resolution" else "is not running from")

    def test_stale_or_empty_spotlight_results_cannot_report_success(self):
        for failure in ("stale", "empty"):
            with self.subTest(failure=failure):
                self.bundle(self.source)
                self.state(indexed=[str(self.repo / "build/Removed/Unexpected Product.app")],
                           stale_index=failure == "stale", empty_index=failure == "empty")
                self.fails(reason="Duplicate/index verification incomplete")

    def test_running_duplicate_is_preserved(self):
        self.bundle(self.source)
        duplicate = self.repo / "build/Debug/Active.app"
        self.bundle(duplicate)
        self.state(running=[dict(path=str(duplicate), executable=str(duplicate / "Contents/MacOS/Sample"), finished=True)])
        self.fails(reason="duplicate is still running")
        self.assertTrue(duplicate.exists())
        self.assertTrue(self.source.exists())

    def test_unsafe_paths_and_symlinks_are_preserved(self):
        self.bundle(self.source)
        outside = self.root / "Source.app"
        self.bundle(outside)
        self.fails("--derived-data", "..", reason="DerivedData must be inside")
        self.fails("--cleanup-root", str(self.root), reason="Cleanup root must be inside")
        link = self.repo / "build/Sample.app"
        link.symlink_to(outside, target_is_directory=True)
        self.fails(reason="preserved symlink")
        self.assertTrue(outside.exists())
        self.assertTrue(link.is_symlink())


if __name__ == "__main__":
    unittest.main(verbosity=2)
