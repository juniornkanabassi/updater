# macOS 26 visual references

The opt-in UI suite compares ten reviewed PNGs on macOS 26. The seven
`main-*` images are historical references whose compared regions contain only
production detail-header/body content (including RTL, empty and error states).
Their mock sidebar pixels are excluded. The current detail fixture leaves that
area blank; sidebar tests open LatestMainWindowScene and inspect its real rows.
Three references cover production locations. Four update-action and toolbar
shelf PNGs are retained as historical references outside the executed suite.
All retained PNGs preserve their reviewed pixels.
Original provenance: commit `a0fb2c5`, [CI run 36529255081](https://github.com/Ertyoii/Latest/actions/runs/36529255081).

The three `locations-*` references use SwiftUI folder symbols, matching the
settings redesign. They were reviewed from macOS 26/Xcode 26.6 captures in
[CI run 37122943394](https://github.com/Ertyoii/Latest/actions/runs/37122943394),
source revision `023ca00`. Original and candidate production settings were
also reviewed on the same local system. Normalized pixel comparison found
changes only in the two reachable-folder icons; all other pixels matched.
Comparison thresholds remain unchanged.

The two `toolbar-state-shelf-*` references were reviewed on 2026-10-03 using
macOS 26.6.2 and Xcode 26.5. Original source `deea228` and the candidate were
captured on the same VM. Pixel differences are confined to the scanning
indicator: it now uses the empty linear progress track instead of a spinner.
Ready and checking states retain identical pixels. The production-window
regression also verifies that learning the app count preserves the empty bar,
checking advances it, and completion removes it.

For an intentional visual change, compare the original and candidate on the
same system, then run `LATEST_RECORD_VISUAL_BASELINES=1 ./script/test.sh --ui` on
macOS 26. Review `/tmp/latest-visual-candidates` before copying approved images
here. Tests keep comparing against existing references until they are updated.

The update-state and toolbar-state shelf PNGs are retained as historical reviewed references. They are no longer executed: functional state mapping, real toolbar lifecycle, and production actions own that coverage. Current component appearance checks cover detail content and locations.
