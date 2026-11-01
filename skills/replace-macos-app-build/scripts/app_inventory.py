#!/usr/bin/env python3
"""Discover app bundles independently of their product names; enforce cleanup scope."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
XCODE_OUTPUT = Path.home() / "Library/Developer/Xcode/DerivedData"
RUNNING_APPS = r"""
ObjC.import('AppKit');
var result = [], apps = $.NSWorkspace.sharedWorkspace.runningApplications;
for (var i = 0; i < apps.count; i++) {
    var app = apps.objectAtIndex(i);
    if (!app.bundleURL.isNil()) {
        result.push({path: ObjC.unwrap(app.bundleURL.path),
                     executable: app.executableURL.isNil() ? null : ObjC.unwrap(app.executableURL.path),
                     finished: Boolean(app.finishedLaunching)});
    }
}
JSON.stringify(result);
"""


def command(args):
    result = subprocess.run(args, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError(f"Discovery/verification failed: {args[0]}: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def inside(path, root):
    return path == root or root in path.parents


def worktree_roots(project):
    probe = subprocess.run(["git", "-C", str(project), "rev-parse", "--is-inside-work-tree"], capture_output=True)
    if probe.returncode:
        # This skill also supports projects without Git.
        return [project / "build"]
    fields = command(["git", "-C", str(project), "worktree", "list", "--porcelain", "-z"]).split(b"\0")
    return [Path(os.fsdecode(field[len(b"worktree "):])) / "build"
            for field in fields if field.startswith(b"worktree ")]


def bundle(path):
    try:
        with (path / "Contents/Info.plist").open("rb") as file:
            return plistlib.load(file)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise RuntimeError(f"Cannot read bundle identity: {path}: {error}") from error


def names(path, info):
    result = {path.stem, info.get("CFBundleName", ""), info.get("CFBundleDisplayName", "")}
    resources = path / "Contents/Resources"
    if resources.is_dir():
        for strings in resources.glob("*.lproj/InfoPlist.strings"):
            # InfoPlist.strings can be UTF-16 OpenStep plists, which plistlib cannot read.
            localized = json.loads(command(["plutil", "-convert", "json", "-o", "-", str(strings)]))
            result.update(localized.get(key, "") for key in ("CFBundleName", "CFBundleDisplayName"))
    return {name.casefold() for name in result if isinstance(name, str) and name}


def related(candidate_names, expected_names):
    return any(candidate.startswith(expected) for candidate in candidate_names for expected in expected_names)


def filesystem_apps(roots):
    found = set()
    for root in roots:
        if root.is_symlink() or root.resolve() != root:
            raise RuntimeError(f"Refusing a symlinked output root: {root}")
        if not root.exists():
            continue
        if not root.is_dir():
            raise RuntimeError(f"Output root is not a directory: {root}")
        def failed(error):
            raise RuntimeError(f"Cannot enumerate output root {root}: {error}") from error
        for directory, children, _ in os.walk(root, onerror=failed, followlinks=False):
            for child in children[:]:
                path = Path(directory) / child
                if child.endswith(".app"):
                    found.add(path)
                    children.remove(child)  # Never treat an embedded helper as an independent product.
                elif child == ".git" or path.is_symlink():
                    children.remove(child)
    return found


def registered_apps(identifiers, expected_names):
    dump = command([LSREGISTER, "-dump"]).decode(errors="replace")
    result = set()
    for record in re.split(r"\n-{10,}\n", dump):
        path = re.search(r"^path:\s+(.+?)(?: \(0x[0-9a-fA-F]+\))?$", record, re.M)
        identity = re.search(r"^identifier:\s+(\S+)", record, re.M)
        labels = "\n".join(line for line in record.splitlines()
                           if re.match(r"^(?:name|displayName|localizedNames|localizedShortNames):", line)).casefold()
        if path and ((identity and identity[1] in identifiers)
                     or any(name in labels for name in expected_names)):
            result.add(Path(path[1]))
    return result


def spotlight_apps(identifiers, expected_names):
    def quote(value):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
    clauses = [f"kMDItemCFBundleIdentifier == {quote(identity)}" for identity in sorted(identifiers)]
    for name in sorted(expected_names):
        # Names are discovery hints, never deletion authorization.
        literal = name.replace("*", "\\*").replace("?", "\\?") + "*"
        clauses += [f"{key} == {quote(literal)}cd" for key in ("kMDItemDisplayName", "kMDItemFSName")]
    query = 'kMDItemContentType == "com.apple.application-bundle" && (' + " || ".join(clauses) + ')'
    return {Path(os.fsdecode(path)) for path in command(["mdfind", "-0", query]).split(b"\0") if path}


def running_apps():
    result = json.loads(command(["osascript", "-l", "JavaScript", "-e", RUNNING_APPS]))
    if not isinstance(result, list):
        raise RuntimeError("Cannot read running app inventory")
    return result


def inventory(args):
    project = Path(args.project_root).resolve()
    installed = Path(args.installed_app)
    known_roots = list(dict.fromkeys([project / "build", XCODE_OUTPUT, *worktree_roots(project)]))
    allowed_roots = [project / "build", XCODE_OUTPUT]
    for supplied in args.cleanup_root:
        root = Path(supplied).absolute()
        if root.resolve() != root or not any(inside(root, base) for base in known_roots):
            raise RuntimeError(f"Cleanup root must be inside a Git worktree's build/ or Xcode DerivedData: {root}")
        allowed_roots.append(root)
    scan_roots = list(dict.fromkeys([*known_roots, *allowed_roots]))
    identifiers = set(args.cleanup_bundle_id)
    if args.bundle_id:
        identifiers.add(args.bundle_id)
    if any(not re.fullmatch(r"[A-Za-z0-9.-]+", identity) for identity in identifiers):
        raise RuntimeError("Invalid cleanup bundle identifier")
    expected_names = {name.casefold() for name in args.artifact_name}
    for target in (installed, Path(args.built_app)):
        expected_names.update(names(target, bundle(target)))
    retained = {Path(path).absolute() for path in args.preserve_app}
    if args.keep_build:
        retained.add(Path(args.built_app))
    files = filesystem_apps(scan_roots)
    registered = registered_apps(identifiers, expected_names)
    indexed = spotlight_apps(identifiers, expected_names)
    rows = []
    for path in sorted(files | registered | indexed | {installed}):
        info = bundle(path)
        identity = info.get("CFBundleIdentifier")
        candidate_names = names(path, info)
        # mdfind already matched the expected metadata. A deleted or renamed
        # bundle can no longer supply the ID/localized name that matched its index.
        if path not in indexed and identity not in identifiers and not related(candidate_names, expected_names):
            continue
        root = next((base for base in allowed_roots if inside(path, base)), None)
        if path == installed:
            action = "installed"
        elif path in retained:
            action = "retained explicitly"
        elif not path.exists():
            action = "stale index/registration"
        elif path.is_symlink() or path.resolve() != path:
            action = "preserved symlink"
        elif not identity:
            action = "preserved unidentified bundle"
        elif identity not in identifiers:
            action = "preserved different identity; use --cleanup-bundle-id only if authorized"
        elif root is None:
            action = "preserved outside cleanup roots; use --cleanup-root only if authorized"
        else:
            action = "remove"
        sources = [label for label, paths in (("filesystem", files), ("LaunchServices", registered), ("Spotlight", indexed))
                   if path in paths]
        row = dict(path=str(path), identifier=identity, action=action, sources=sources)
        rows.append(row)
        print(f"{action}: {path} [{identity or 'unknown'}; {', '.join(sources)}]")
    if args.remove:
        active = {Path(app["path"]).resolve() for app in running_apps()}
        candidates = [row for row in rows if row["action"] == "remove"]
        if any(Path(row["path"]).resolve() in active for row in candidates):
            raise RuntimeError("A duplicate is still running; preserving all build products. Quit it before cleanup.")
        for row in candidates:
            path = Path(row["path"])
            # Recheck immediately before deletion, including parent symlinks and identity changes.
            if path.resolve() != path or path.is_symlink() or bundle(path).get("CFBundleIdentifier") != row["identifier"]:
                raise RuntimeError(f"Candidate changed during cleanup; preserving: {path}")
            command([LSREGISTER, "-u", str(path)])
            shutil.rmtree(path)
            print(f"Removed {path}")
    if args.verify:
        leftovers = [row for row in rows if row["action"] not in ("installed", "retained explicitly")
                     and (row["action"] != "preserved unidentified bundle" or any(s != "filesystem" for s in row["sources"]))]
        # Missing LaunchServices records can linger; exact resolution is verified separately.
        leftovers = [row for row in leftovers if row["action"] != "stale index/registration" or "Spotlight" in row["sources"]]
        if leftovers or installed not in indexed:
            raise RuntimeError("Duplicate/index verification incomplete. Listed leftovers are preserved; Spotlight may need time to refresh.")
        print("Verified filesystem, LaunchServices and Spotlight app inventory.")


def verify_launch(args):
    installed = Path(args.installed_app)
    info = bundle(installed)
    expected = {"CFBundleIdentifier": args.bundle_id,
                "CFBundleShortVersionString": args.version, "CFBundleVersion": args.build}
    if any(info.get(key) != value for key, value in expected.items()):
        raise RuntimeError("Installed bundle identity/version differs from the verified build")
    resolved = command(["osascript", "-e", f'POSIX path of (path to app id "{args.bundle_id}")']).decode().strip()
    if Path(resolved) != installed or installed.is_symlink():
        raise RuntimeError(f"LaunchServices resolved to {resolved}, expected {installed}")
    print(f"LaunchServices resolves to {installed}")
    if args.require_running:
        executable = installed / "Contents/MacOS" / info["CFBundleExecutable"]
        matches = [app for app in running_apps() if Path(app["path"]) == installed]
        if not matches or any(app["executable"] != str(executable) or not app["finished"] for app in matches):
            raise RuntimeError(f"Installed app is not running from {executable} with startup complete")
        print(f"Running installed executable: {executable}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    scan = subparsers.add_parser("inventory")
    for flag in ("project-root", "installed-app", "built-app"):
        scan.add_argument("--" + flag, required=True)
    scan.add_argument("--bundle-id", default="")
    for flag in ("artifact-name", "cleanup-bundle-id", "cleanup-root", "preserve-app"):
        scan.add_argument("--" + flag, action="append", default=[])
    for flag in ("keep-build", "remove", "verify"):
        scan.add_argument("--" + flag, action="store_true")
    launch = subparsers.add_parser("verify-launch")
    for flag in ("installed-app", "bundle-id", "version", "build"):
        launch.add_argument("--" + flag, required=True)
    launch.add_argument("--require-running", action="store_true")
    args = parser.parse_args()
    try:
        (inventory if args.command == "inventory" else verify_launch)(args)
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
