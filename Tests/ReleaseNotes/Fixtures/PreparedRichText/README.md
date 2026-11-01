# Prepared release-note compatibility fixtures

The HTML and v2 RTF payloads were recorded from the original AppKit preparation at commit `3da9579` on macOS 27, before replacing its semantic preparation with SwiftUI `AttributedString`.

On 2026-11-01, the overscroll fix updated the four HTML fixtures from `8336ae3` only to add `overscroll-behavior: none` to `:root`, matching the reviewed change that disables release-note edge bounce on both axes. Their bodies and the original v2 RTF payloads remain unchanged.

On 2026-11-01, the white-flash fix updated only the page shell of the four `notes-*.html` fixtures from base commit `8336ae3`: an early `color-scheme` meta tag and a transparent body background let the native detail surface own the background while WebKit synchronizes appearance. These were targeted text edits, not regenerated renderer output. Each original `<body>` and its rich-text markup remain byte-identical, and all legacy RTF plist payloads remain unchanged. The white-flash change did not modify scrolling styles.

`ReleaseNotesMarkupTest.testPreparedRichTextMatchesOriginalHTMLAndLegacyCache` requires identical HTML for headings, combined inline styles, links, nested lists, code blocks, Unicode, HTML and plain text. It also requires existing RTF payloads and newly written payloads to render the same HTML. The original payload timestamps are fixture metadata; these tests decode the payload directly without renewing or checking its cache lifetime.

Regenerate only from a reviewed original implementation when intentionally changing the rendering contract.
