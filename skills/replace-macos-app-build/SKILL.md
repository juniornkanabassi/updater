---
name: replace-macos-app-build
description: Build and replace a local macOS app in /Applications, remove duplicate build copies, and repair LaunchServices or Spotlight resolution. Use for installing the newest local app build or fixing duplicate app entries.
---

# Replace macOS App Build

Deliver one installed app at `/Applications/<install-name>.app`, with the requested version and macOS resolving to that path. Build products are temporary installation inputs. Remove them after verifying the installed copy; retaining the fresh build requires an explicit user request.

Follow the user's current instructions and existing authorization. Infer routine project, scheme, and app names from the repository and installed bundle. Ask only when identity or scope remains ambiguous. For Latest, a replacement request includes preparing and pushing relevant unshipped changes as described below. For other repositories, follow their release authorization. Changes to other apps and restarting Dock require separate authorization.

## Decide the version, then ship the source

1. Read the working-tree status, configured remote/upstream, current marketing version, and release notes. Query the latest published release for this repository and channel (for GitHub, use `gh release list` / `gh release view`; exclude drafts and unrelated prereleases). Do not use the installed app's version as the published version.
2. If there are no published releases, use the distribution branch specified by the repository's current guidance. Latest Dev uses `origin/master`: fetch that branch and read its marketing version, release notes, and commit as the published-source fallback. Old upstream tags are not Latest Dev releases. Report which source was used. A failed remote lookup is unknown, not proof that no release exists.
3. Compare versions numerically and compare relevant source changes with that published revision. If the current version is already newer, retain it. If it equals the published version and relevant changes remain unshipped, bump once using the repository's version convention and update release notes. If the version is behind, reconcile the remote state before choosing a version; never downgrade or reset unrelated work. If the requested source is already shipped, reuse its version without an empty release commit. Let the project's build-number mechanism own the build number.
4. Commit only relevant changes and push to the intended branch successfully before building and replacing. Reuse an existing unpushed commit when appropriate. Stop if the push fails; do not install an unpublished candidate while reporting it as shipped.

Replacement is a version-and-install workflow. Do not run the app's test suite, visual snapshots, benchmarks, evaluations, baseline comparisons, or test audits as part of it. Use validation evidence from the implementation task when available; do not rerun it. A build and installed-bundle verification are required. Run a test or evaluation only if the user separately requests it in the current task.

## Execute

Use [the installer](scripts/replace_macos_app_build.sh) relative to **this loaded skill's folder**. Do not silently substitute a different repository copy.

First run the intended command with `--dry-run`. This performs a read-only filesystem, LaunchServices and Spotlight inventory, including all Git worktree build roots. Inspect exact paths and identifiers; localized `InfoPlist.strings` can make differently named preview/test apps appear with the production name. Folder search results are not duplicate apps.

From the repository root, start with this command for Latest (append `--dry-run` for inventory):

```sh
<skill-folder>/scripts/replace_macos_app_build.sh \
  --project Latest.xcodeproj --scheme Latest \
  --configuration Release --derived-data build/DerivedData \
  --app-name 'Latest Dev' --install-name 'Latest Dev' \
  --bundle-id com.max-langer.Latest.dev --artifact-name Latest \
  --code-signing YES --open
```

- Default to **Release** for normal use. The product name may still contain `Dev`; that is separate from the build configuration. Honor an explicit Debug request, but still remove its build copy after installation unless the user asks to keep it (`--keep-build`).
- Inspect installed and built bundle identity before replacement. Never overwrite a different bundle identifier. The script verifies an expected identifier, stops the matching app, copies it, and checks complete bundle content before cleanup.
- Discovery reads bundle metadata for every top-level app product under repository `build/`, user Xcode DerivedData and Git worktree build roots, regardless of filename. LaunchServices and Spotlight add paths outside those trees. Discovery hints such as names, localized names or bundle-ID prefixes do **not** authorize deletion.
- Cleanup defaults to the installed bundle's exact identity inside the current repository's `build/` and user Xcode DerivedData. For relevant inactive worktrees, append `--cleanup-root '/absolute/worktree/build'`. For authorized experimental app copies, append exact `--cleanup-bundle-id` values from the inventory. Latest's historical experiments used `com.max-langer.latest.unified-preview` and `com.max-langer.latest.unified-ui-tests`; include them only when their generated copies are within the requested cleanup scope. Worktree source folders remain untouched.
- Use `--preserve-app '/absolute/baseline/App.app'` for a reviewed baseline or a copy explicitly retained by the user. Inspect active work before adding cleanup roots. The script refuses to delete running products, symlinks or unreadable identities, unregisters eligible products, and removes only their `.app` directories—including the fresh installation source. Preserve unrelated apps, source, visual references, caches, logs and result bundles. Report unidentified nonindexed build stubs separately.
- Register and index `/Applications` after cleanup. Open that installed path when requested or when completing the normal replacement workflow. Restart Dock only when explicitly requested or a persistent Dock item still points at the removed copy.
- `--dry-run` shows actual candidates without building or changing app/index state; `--clean-artifacts` remains accepted for older callers, but cleanup is now the default. Discovery and traversal failures stop the script before replacement.

## Verify and report

Verify marketing/build version and bundle identifier from the installed plist. Verify the full copy **before** removing the source: Debug executables can be launcher stubs whose hashes remain unchanged; the `.debug.dylib` contains the implementation.

The script asserts installed identity/version, exact LaunchServices resolution and, with `--open`, the running executable and completed startup. It then independently re-enumerates filesystem, LaunchServices and Spotlight candidates. Existing duplicates, undeclared variant IDs/roots and pending Spotlight records produce a nonzero exit after bounded retries, with retained paths printed. An empty Spotlight query is not success: the installed app must appear. Explicitly retained copies remain listed as exceptions.

Spotlight can lag; distinguish stale indexed entries from files that still exist. Report an incomplete verification even if installation succeeded, and do not claim the Spotlight UI is fixed without observing it. Use targeted unregister/import operations; avoid global LaunchServices/Spotlight resets. For future preview/test builds, use distinct **localized** bundle names and keep transient output in a Spotlight-excluded folder when authorized. Do not change Search Privacy settings as an automatic side effect.

On build, identity, discovery or copy-verification failure, stop before deleting build products. Keep enough evidence to recover and report the actual blocker. For installer changes, run `bash -n scripts/replace_macos_app_build.sh` and `python3 scripts/test_replace_macos_app_build.py` from the skill folder. Use isolated bundles for destructive regression tests; a skill edit alone does not authorize replacing the user's installed app.

When this skill has a tracked repository copy and a separate installed copy, commit/push the tracked changes and synchronize the complete skill folder to the user-selected installed location. Verify the copies match; changing only the tracked copy leaves future invocations on the old implementation. Tooling-only fixes do not require an app version bump.

Report the installed version/path, cleanup result, and any unresolved resolution issue concisely. If permission review blocks a required operation, identify the operation and reason rather than reporting completion.
