# Updater

Updater is a macOS app that finds and installs updates for the apps on a Mac, whether they came from the App Store, Sparkle feeds or Homebrew. It targets macOS 26 and later and is a personal project by Junior Nkana Bassi; it has no public releases yet.

It is based on [Latest](https://github.com/mangerlahn/Latest) by Max Langer and the [Ertyoii fork](https://github.com/Ertyoii/Latest) of it, and is licensed under [GPL-3.0](LICENSE.md). Upstream and dependency notices are retained, and the full GPL and Sparkle notices are available offline in Help → Licenses.

![Updater](latest.png)

## Development

Requires Xcode 26.5 or later and `ripgrep`. Development and CI use `main`; CI uses Xcode 26.6. Open the `Updater` scheme in `Latest.xcodeproj` (the project file keeps its upstream name), or run:

```sh
brew install ripgrep
./script/build_and_run.sh
./script/test.sh
./script/format.sh --check
./script/lint.sh
```

`build_and_run.sh --help` lists launch, debugger, and logging options. Add `--signed` after a mode for an Apple Development build; the App Store installation helper requires the app and helper to share a valid signing identity.

`test.sh` runs script regressions, architecture checks, and the **unhosted** `Latest Unit Tests` target under `xctest`. Set `UPDATER_BUILD_DIR` (for example `/private/tmp/updater-build/test`) to keep build products out of iCloud-synced folders. It compiles the same production domain, snapshot, progress-presentation, and bounded-executor sources directly into the test bundle. It has no application dependency or `TEST_HOST`: `main.swift`, SwiftUI scenes, live discovery, and network services are outside its source membership. Preference tests use disposable suites, and filesystem tests use temporary fixtures. Focus a function with `-only-testing:'Latest Unit Tests/VersionParserTest/testBuildNumberParsing'`. Coverage is opt-in with `--coverage`; run `./script/format.sh` to apply the pinned formatting rules.

`lint.sh` downloads and verifies the pinned SwiftLint 0.65.1 portable binary on first use, then runs the focused correctness rules in `.swiftlint.yml` with warnings treated as failures. Formatting stays with Apple `swift-format`; naming and length preferences are not lint gates. Literal release-note regexes have a documented, scoped `force_try` exception.

`./script/lint.sh --analyze` makes fresh isolated unsigned builds of both schemes and reports unused-declaration candidates as advisory warnings. It compiles hosted, unhosted, and opt-in audit callers without running tests or opening apps. Confirmed runtime, binding, and cross-module false positives have documented declaration-level exceptions; new findings require review before deletion. `unused_import` is disabled because SourceKit reports circular references in the conditional audit on Swift 6.4; analyzer errors still fail the command. CI runs formatting, strict lint, declaration analysis, and the existing test gates, preserving analysis/build logs under `build/`.

`./script/test.sh --integration` runs the application-hosted `Latest Tests` target in a background host: platform adapters, service lifecycles, storage, offscreen layout, and WebKit compatibility. The host suppresses production startup and activation. Focus it with `--integration -only-testing:'Latest Tests/UpdateQueueTest'`. `./script/test.sh --ui` selects hosted production-window, input, accessibility, and screenshot checks and may take focus. These instantiate production views/scenes in the host; this project has no external XCUIAutomation target. `--all` runs unit, integration, then UI checks sequentially. Benchmarks and live catalog audits keep their separate commands.

In Xcode, choose the `Latest Unit Tests` scheme for app-free tests. The `Updater` scheme defaults to the `LatestIntegration` test plan; select `LatestUI` explicitly for foreground checks. Dedicated benchmark plans preserve the Release runners. CI runs all three correctness lanes. For another host OS, see [testing on macOS 26](docs/macos26-testing.md).

The UI fixtures request foreground activation of the existing host through LaunchServices. Full-window captures hand activation to Finder, use an opaque screen backdrop, and wait for settled frames. Same-host originals for that setup live in `build/production-visual-reference/main-window-scene-inactive`; the legacy `main-window-scene` references remain separate. Create references from original production code and compare original/candidate pixels on the same host before adopting a new capture setup.

Apple documents [`TEST_HOST`](https://developer.apple.com/documentation/xcode/build-settings-reference) as the executable receiving an injected test bundle and supports [test plans](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback) for different workflows. The source-membership split is this repository's engineering choice: a library is unnecessary for these independent sources, and retaining hosted tests preserves actual platform integration. Apple recommends [Swift Testing for new Swift unit/integration tests](https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project); existing XCTest coverage remains supported. [Swift Testing supports incremental coexistence](https://github.com/swiftlang/swift-testing), so changing assertion frameworks is independent of removing the app host. Apple's [testing guidance](https://developer.apple.com/videos/play/wwdc2018/417/) also emphasizes fast, isolated behavior checks alongside fewer integration/UI checks.

## Reading the code

The [development guide](docs/Development.md) gives a reading order, design rationale, and links to Swift and SwiftUI guidance.

| Directory | Responsibility |
| --- | --- |
| `Latest/App` | Assembly, scenes, commands, and lifecycle |
| `Latest/Domain` | Immutable app metadata and version rules |
| `Latest/Features` | SwiftUI presentation and feature state |
| `Latest/Services` | Discovery, update checking, and release notes |
| `Latest/Platform` | AppKit, WebKit compatibility, update sources, and installers |
| `Latest/Support` | Preferences, presentation helpers, and shared infrastructure |
| `Tests` | Behavior, integration, visual, and performance contracts |
| `script` | Local build, validation, measurement, and audit commands |

SwiftUI owns the scenes, search, rows, settings, and detail controls. macOS 26 and 27 share `UpdatesScrollList`, including row geometry, selection, keyboard navigation, and context menus. A small AppKit bridge configures overlay scroll indicators and disables edge bounce. Release notes use WebKit for text selection and scrolling; native services and window hooks remain at platform boundaries.

Discovery publishes apps promptly while update providers run. During a scan, visible apps share the neutral Installed Apps section and retain their previous/discovery order as versions and dates resolve. Apps with unresolved update sources show Checking rather than an unsupported indicator. Completed scans apply the usual sections and displayed-date sorting once. Search and explicit preferences remain usable, refresh retains known results until replaced, and selection stays attached to the installed path. Remote release-note catalog refresh runs alongside discovery using the bundled catalog initially. Keyboard selection updates the detail header immediately and waits for selection to settle before hashing and loading notes; mouse selection loads notes immediately.

## Background, menu bar and permissions

Each watched folder has a recursive FSEvents stream with a 2 second latency. A change inside a known app re-reads only that app; a new or removed app rescans the folder. Updater checks on launch, after wake and on a timer (Settings: off, 1, 4, 12 or 24 hours; 4 by default), skips a check while one runs, and never installs on its own. After each check it records the waiting updates; after a background or folder-triggered check (not a manual one) it posts one summary notification for updates it has not announced before, asking for permission the first time. The menu bar item (it can be hidden in Settings) shows the waiting count and list, Update All with the window's rules, Check Now, Open Updater and Quit; while it shows, closing the window leaves Updater running. Settings → Permissions shows App Management, the update helper, notifications and Full Disk Access, each with its state and a button to its System Settings pane. A failure recorded as needing App Management offers Open Settings next to Retry; the refusal shows as history ("Last attempt was blocked by App Management"), not as the current state. Casks that need administrator rights stay a Terminal hand-off: `sudo` only accepts the plain password, so no askpass helper ships.

## Updating applications

Features call `AppUpdating`; platform adapters own the update mechanism. Sparkle is pinned through Swift Package Manager. Native Mac App Store apps update within Updater; macOS 26.1+ uses a privileged helper. Wrapped iOS apps open the App Store. Before downloading, Updater verifies signing, approval, and a live response from the bundled helper. Legacy helper registrations migrate to one stable fork-specific launchd label, rebuilding their parent-app association without resetting other background items. Migration and repair share the same active-installation protections. An unreachable or outdated daemon gets one registration refresh followed by bounded readiness checks. A persistent setup sheet offers repair, System Settings approval, cancellation, and an App Store fallback; pending updates resume only after readiness succeeds. Readiness is checked again when a queued update starts. Helper refresh is blocked while Updater is installing another app, and an installation is never automatically replayed after a lost connection.

If a Sparkle app declines to quit, the update stays active and its Retry control sends another quit request. Save your work before retrying. Installation remains protected from cancellation once Sparkle takes over.

Signed standalone bundle replacement supports Docker Desktop, Telegram Desktop, Zed, Chrome, Bruno, 1Password, and Delta. Homebrew downloads require the expected bundle identifier and cask. Each install fetches fresh metadata, verifies available checksums, signing identity, architecture, and minimum OS, and keeps the original until replacement succeeds. Running apps require confirmation to quit and reopen; package installers and companion services use separate paths. Discord updates open Discord's native updater, which manages its host-version database and cached bundles together; replacing only its application bundle can trigger a rollback on launch.

Obsidian's installed version comes from its ASAR payload; Delta's comes from validated metadata in its main executable, since its plist and bundled CLI can report older versions. Obsidian public payload updates verify the vendor checksum and RSA signature. Early-access preferences are respected: authenticated updates open Obsidian, and incompatible launchers open the official installer page. Ghostty uses its official Sparkle feed.

## Release notes

`Latest/Resources/LatestReleaseNotes.json` supplies version-matched offline notes inherited from the Ertyoii fork. Updater does not update itself yet: it has no appcast or public key configured, and no menu item that opens a releases page.

Notes can load even if update checking fails. A failed or metadata-only source falls back to the vendor catalog. Notes target the available update or installed version; broad-version and latest-section fallbacks retain a degraded quality rating. Preparation, display, and new cache entries share immutable semantic text; older RTF caches use a narrow compatibility reader. Only genuine, nonempty notes are reused from the rendered cache; degraded fallbacks are retried so a recovered source can replace them.

```sh
./script/audit_release_notes.sh
./script/audit_release_notes.sh --installed
./script/audit_release_notes.sh --catalog /path/to/cask.json
```

The default audit is offline. Live audits save reports and HTML under `build/` and use an isolated cache. `audit_release_note_coverage.sh` checks source routes, not whether the remote notes are usable.

## Performance and visual checks

```sh
./script/benchmark_complexity.sh
./script/benchmark_app.sh current
```

Optional Release benchmarks measure data processing, startup, selection, release notes, and memory. Compare results on the same hardware and workload. Reports and test output go under `build/`.

The UI lane checks keyboard navigation, focus, selection, scrolling, accessibility, and appearance. Performance measurements supplement these behavior checks.

Visual tests capture the production window with offline data at a fixed position and inactive state, with an opaque backdrop behind native materials. Images in `build/production-visuals/main-window-scene` compare pixel-for-pixel with same-host originals in `build/production-visual-reference/main-window-scene`; the test skips explicitly when originals are absent. Preserve those originals and their provenance. The macOS 26 [component references](Tests/VisualBaselines/macos-26/README.md) are checked in separately.

Build products, logs, and captures can be regenerated. Keep visual references and any configured macOS 26 VM when cleaning `build/`.

## Build and install

```sh
./build.sh              # signed Release build, verified, zipped into ../Outputs/Updater-<version>.zip
./install.sh            # installs into /Applications/JuniorOS Apps (override with UPDATER_INSTALL_ROOT)
```

Both use the Apple Development identity for team M6L2VW4W5Z and build under `/private/tmp/updater-build`. `build.sh` also checks that the helper launch constraint names that team. The install helper reads the team from the `DEVELOPMENT_TEAM` build setting through `UpdaterTeamIdentifier` in both Info.plists, and the two helper launchd plists in `UpdateInstaller/` hard-code it (launch constraints cannot use substitution).

## Licence

Based on [Latest by Max Langer and contributors](https://github.com/mangerlahn/Latest) and the [Ertyoii fork](https://github.com/Ertyoii/Latest). Modifications © 2026 Junior Nkana Bassi; upstream and dependency notices are retained. Full GPL and Sparkle notices are available offline in Help → Licenses.

Distributed under [GPL version 3](LICENSE.md). Binary distributions must include corresponding source. This software comes without warranty.
