//
//  ReleaseNotesMarkupTest.swift
//  Latest Tests
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import CryptoKit
import XCTest

@testable import Latest

final class ReleaseNotesMarkupTest: XCTestCase {
  func testEntitiesAreDecodedExactlyOnce() {
    XCTAssertEqual(
      ReleaseNotesMarkup.decodingHTMLEntities(
        in:
          "&amp;#39; &amp;lt; &lt; &amp; &unknown; &#128640; &#x1F680; &#X1F680; &#xD800; &#999999999999;"
      ),
      "&#39; &lt; < & &unknown; 🚀 🚀 🚀 &#xD800; &#999999999999;")
  }

  func testHTMLFormattingPreservesFencedAndInlineCodeLiterals() {
    let markdown = """
      # Release 2.0
      Fixed rendering with <strong>emphasis</strong>.

      ````html
      <strong>literal</strong>
      ```
      <i>still literal</i>
      ````

      Inline `<b>literal</b>` and ``<code>`nested`</code>``.
      """
    let content = ReleaseNotesContent(ReleaseNotesDocument.prepare(markdown))
    for literal in [
      "<strong>literal</strong>", "<i>still literal</i>", "<b>literal</b>", "<code>`nested`</code>",
    ] {
      XCTAssertTrue(
        content.runs.contains { $0.text.contains(literal) && $0.style?.monospaced == true }, literal
      )
    }
    XCTAssertTrue(content.runs.contains { $0.text == "emphasis" && $0.style?.bold == true })
  }

  func testCodeShieldingRespectsMarkdownBlockBoundariesAndMixedFormatting() {
    for markdown in [
      "`before\n\nFixed <strong>important</strong> changes.\n\nafter`",
      "```<b>literal</b>```\nFixed <strong>important</strong>.",
      "<strong>important `<i>literal</i>`</strong>",
      "Fixed <strong>important\ncontinued</strong> changes.",
      "你好🙂 `🚀 <i>literal</i>` and <strong>important</strong>.",
      "Inline `<i>literal</i>🚀` and <strong>important</strong>.",
      "Inline `<i>literal</i>e\u{301}` and <strong>important</strong>.",
    ] {
      let content = ReleaseNotesContent(ReleaseNotesDocument.prepare(markdown))
      XCTAssertTrue(
        content.runs.contains { $0.text.contains("important") && $0.style?.bold == true }, markdown)
      XCTAssertFalse(content.string.contains("�"), "Preserve complete Unicode scalars")
      if markdown.contains("<i>literal</i>") {
        XCTAssertTrue(
          content.runs.contains {
            $0.text.contains("<i>literal</i>") && $0.style?.monospaced == true
          })
      }
    }
  }

  func testCodeAfterDownloadButtonPreservesHTMLAcrossLineEndings() {
    let button = "<a href=\"download\"><img src=\"badge.png\"></a>"
    for newline in ["\n", "\r\n", "\r"] {
      let markdown = [button, "```html", button, "```"].joined(separator: newline)
      let content = ReleaseNotesContent(ReleaseNotesDocument.prepare(markdown))
      XCTAssertEqual(content.string.trimmingCharacters(in: .whitespacesAndNewlines), button)
      XCTAssertTrue(
        content.runs.contains { $0.text.contains(button) && $0.style?.monospaced == true })
    }
  }

  @MainActor
  func testZoomKeepsTheMacFixWhenTwoPatchVersionsShareAReleaseDate() async throws {
    let html = """
      <h2>September 24, 2026</h2>
      <p>Note: Two versions were released: 7.1.9 and 7.2.2.</p>
      <h3>Full versions for 7.2.2</h3><p>macOS</p><p>7.2.2 (88465)</p>
      <h3>Resolved issues in version 7.2.2</h3>
      <table><tr><th>Description</th><th>Platforms</th></tr>
      <tr><td>Minor bug fix</td><td>macOS</td></tr></table>
      <h3>Full versions for 7.1.9</h3><p>7.1.9 (11111)</p>
      <h3>Resolved issues in version 7.1.9</h3><p>Unrelated older train fix</p>
      <h2>September 15, 2026</h2><p>7.1.8</p>
      """
    let result = await ReleaseNotesMarkup.attributedStringFromChangelogByPreparingOffMain(
      fromHTML: html, baseURL: URL(string: "https://support.zoom.com/hc/en/article")!,
      relevantVersion: "7.2.2 (88465)", allowFirstSectionFallback: false)
    let text = try XCTUnwrap(result).get().string
    XCTAssertTrue(text.contains("Minor bug fix"))
    XCTAssertTrue(text.contains("Resolved issues"))
    XCTAssertFalse(text.contains("Full versions"))
    XCTAssertFalse(text.contains("Unrelated older train fix"))
    XCTAssertFalse(text.contains("7.1.9"))
  }

  @MainActor
  func testPreparedRichTextMatchesOriginalHTMLAndLegacyCache() throws {
    let cases = [
      "# Release 2.0\n\n**Bold** *italic* ***both*** `code` ~~removed~~ [link](notes)\n\n- First item\n    - Nested item\n- Second item\n\n1. Ordered\n2. More\n\n```swift\nlet x = 1\nprint(x)\n```",
      "## Changes\n\nCafé 中文 👩🏽‍💻 e\u{301} < & > \"\ttext.\n\n**Bold across\nlines**\n\n> Quote with *emphasis*\n\nPlain paragraph.",
      "<h2>Release 2.0</h2><p>Fixed <b>bold</b> and <i>italic</i> with <code>code</code>.</p><ol start=\"3\"><li>First</li><li><a href=\"notes\">Relative link</a></li></ol><script>ignored()</script>",
      "Fixed launch.\nImproved scrolling.\n\nLast paragraph.",
    ]
    let baseURL = URL(string: "https://example.com/releases/")!
    let texts = try cases.map { source in
      try ReleaseNotesMarkup.attributedString(from: source, baseURL: baseURL).get()
    }
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/PreparedRichText")
    for (index, text) in texts.enumerated() {
      let originalHTML = try String(
        contentsOf: directory.appendingPathComponent("notes-\(index).html"), encoding: .utf8)
      XCTAssertEqual(
        ReleaseNotesWebDocument.html(for: text), originalHTML,
        "Prepared HTML must stay byte-identical")
      let payload = try PropertyListDecoder().decode(
        ReleaseNotesPersistentPayload.self,
        from: Data(contentsOf: directory.appendingPathComponent("notes-\(index).plist")))
      let cached = try XCTUnwrap(ReleaseNotesPersistentCache.resolvedReleaseNotes(from: payload))
      XCTAssertEqual(
        ReleaseNotesWebDocument.html(for: cached.content), originalHTML,
        "Existing RTF cache remains compatible")
      let newPayload = ReleaseNotesPersistentCache.payload(
        from:
          ResolvedReleaseNotes(content: text, quality: .genuine, provenance: .changelog))
      let restored = try XCTUnwrap(
        ReleaseNotesPersistentCache.resolvedReleaseNotes(from: newPayload))
      XCTAssertEqual(ReleaseNotesWebDocument.html(for: restored.content), originalHTML)
    }
  }

  func testHTMLExtractionPreservesNestedElementsAndSiblingBoundaries() throws {
    let first = "<ARTICLE><h2>版本 🚀</h2><article>Nested fix</article><p>First release.</p></ARTICLE>"
    let second = "<article><p>Second release.</p></article>"
    let html = "Before" + first + second + "<article>Unclosed"
    let element = try XCTUnwrap(
      ReleaseNotesMarkup.nextHTMLElement(in: html, tagName: "article", searchStart: html.startIndex)
    )
    XCTAssertEqual(String(html[element.range]), first)
    XCTAssertEqual(
      String(html[element.contentRange]),
      "<h2>版本 🚀</h2><article>Nested fix</article><p>First release.</p>")
    let sibling = try XCTUnwrap(
      ReleaseNotesMarkup.nextHTMLElement(
        in: html, tagName: "article", searchStart: element.range.upperBound))
    XCTAssertEqual(String(html[sibling.range]), second)
    XCTAssertNil(
      ReleaseNotesMarkup.nextHTMLElement(
        in: html, tagName: "article", searchStart: sibling.range.upperBound))
  }

  func testDuplicateReleaseTitlesPreserveBodyAndBlankLines() {
    let repeated = "# Version 2\nVersion 2\n**Version 2**\nFixed crashes.\n\nImproved startup."
    XCTAssertEqual(
      ReleaseNotesMarkup.removingDuplicateLeadingLines(repeated),
      "# Version 2\nFixed crashes.\n\nImproved startup.")
    XCTAssertEqual(
      ReleaseNotesProvider.deduplicating(title: "Version 2", in: repeated),
      "Fixed crashes.\n\nImproved startup.")
    XCTAssertEqual(ReleaseNotesMarkup.removingDuplicateLeadingLines("\n\nBody"), "\n\nBody")
  }

  func testMarkdownDisclosureMarkupDoesNotLeakIntoNotes() {
    let source = """
      # Platform 4.41
      <details>
      <summary>Contributors</summary>
      - Example contributor
      </details>
      <!-- Internal issue reference -->
      Fixed console zooming.
      ```html
      <details>
      ```
      """
    let text = ReleaseNotesContent(ReleaseNotesDocument.prepare(source))
      .string
    XCTAssertTrue(text.contains("Contributors"))
    XCTAssertTrue(text.contains("Fixed console zooming"))
    XCTAssertFalse(text.contains("<summary>"))
    XCTAssertFalse(text.contains("Internal issue"))
    XCTAssertEqual(text.components(separatedBy: "<details>").count - 1, 1)
  }

  func testMarkdownRelativeLinksResolveAgainstTheSourcePage() throws {
    let rendered = try ReleaseNotesMarkup.attributedString(
      from: "See [details](details.md) for the crash fix.",
      baseURL: URL(string: "https://example.com/releases/4.0.md")!
    ).get()
    XCTAssertEqual(
      rendered.runs.first(where: { $0.text == "details" })?.link,
      URL(string: "https://example.com/releases/details.md"))
  }

  func testDatedProductChangelogFallbackPreservesOneAnnouncement() throws {
    let html = """
      <div><span>Sep 10, 2026</span> · <span>Changelog</span></div>
      <h1>Cursor Projects</h1><p>Projects maintains context and coordinates work across agents.</p>
      <h2>Shared context</h2><p>Agents share research and project decisions.</p>
      <div><span>Sep 2, 2026</span> · <span>Changelog</span></div>
      <h1>Previous announcement</h1><p>Older content.</p>
      """
    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantChangelogText(
        fromHTML: html, version: "3.20", pageURL: URL(string: "https://cursor.com/changelog")!,
        allowFirstSectionFallback: true))
    XCTAssertTrue(text.contains("Shared context"))
    XCTAssertFalse(text.contains("Older content"))
  }

  func testZoomIgnoresVersionReferencesOutsideTheVersionMatrix() throws {
    let html = """
      <h2>July 24, 2026</h2><p>Note: This fix is also included in version 7.1.5 and later.</p>
      <p>Full versions</p><p>7.0.6 (84834)</p><h3>Resolved issues</h3><p>Older security fix.</p>
      <h2>July 20, 2026</h2><p>Full versions</p><p>7.1.5 (84650)</p>
      <h3>Resolved issues</h3><p>Fixed a meeting audio crash.</p>
      """
    let text = try XCTUnwrap(
      ZoomReleaseNotesExtractor.zoomReleaseText(
        fromHTML: html, version: "7.1.5", pageURL: URL(string: "https://support.zoom.com/notes")!))
    XCTAssertTrue(text.hasPrefix("Zoom 7.1.5"))
    XCTAssertTrue(text.contains("meeting audio crash"))
    XCTAssertFalse(text.contains("Older security fix"))
  }

  func testVersionMentionsInsideProseDoNotTruncateMarkdown() throws {
    let markdown = """
      Ghostty 1.3.1 includes changes from many contributors.

      ## Highlights

      Ghostty 1.3.0 had a noticeable mouse bug. This issue is now resolved.

      ## Full Changelog

      - Fixed phantom selection after focus changes.
      - Added configurable progress indicators.

      More improvements will ship a bit further out than the 1.3.1 release.
      """
    let text = try ReleaseNotesMarkup.attributedString(
      from: markdown, baseURL: nil, relevantVersion: "1.3.1"
    ).get().string
    XCTAssertTrue(text.contains("includes changes"))
    XCTAssertTrue(text.contains("Added configurable"))
    XCTAssertTrue(text.contains("More improvements"))
  }

  func testAdjacentVersionAndBadgeSpansStaySeparated() throws {
    let html =
      "<h2>Farrago <span>2.2.0</span><span>MacOS 27 Support</span></h2><p>Added support for the new system.</p><h2>Farrago 2.1.5</h2><p>Old notes.</p>"
    let selected = try XCTUnwrap(
      ReleaseNotesMarkup.relevantChangelogText(
        fromHTML: html, version: "2.2.0", pageURL: URL(string: "https://example.com/releases")!,
        allowFirstSectionFallback: false))
    XCTAssertTrue(selected.contains("2.2.0 MacOS"))
    XCTAssertTrue(selected.contains("Added support"))
    XCTAssertFalse(selected.contains("Old notes"))
  }

  func testListContinuationDoesNotRepeatBullet() {
    let text = ReleaseNotesContent(
      ReleaseNotesDocument.prepare(
        "- First paragraph.\n\n  Continuation paragraph.\n\n- Next item."))
    XCTAssertEqual(text.string.filter { $0 == "•" }.count, 2)
  }

  func testEquivalentHTMLAndMarkdownPreserveStructure() throws {
    let html = """
      <h2>Fixes</h2><ul><li><strong>Fixed</strong> the <a href="https://example.com/issues/1">editor</a>.
      <ul><li>Keep <code>code_names</code> and <em>emphasis</em>.</li></ul></li></ul>
      <p>A second paragraph &rsquo; &mdash; &copy;.</p>
      """
    let markdown = """
      ## Fixes

      - **Fixed** the [editor](https://example.com/issues/1).
          - Keep `code_names` and *emphasis*.

      A second paragraph ’ — ©.
      """
    let htmlText = try ReleaseNotesMarkup.attributedString(from: html, baseURL: nil).get()
    let markdownText = try ReleaseNotesMarkup.attributedString(from: markdown, baseURL: nil).get()
    XCTAssertEqual(htmlText.string, markdownText.string)
    XCTAssertEqual(
      htmlText.runs.first(where: { $0.text == "editor" })?.link,
      URL(string: "https://example.com/issues/1"))
    XCTAssertTrue(
      htmlText.runs.first(where: { $0.text == "code_names" })?.style?.monospaced == true)
    let paragraph = try XCTUnwrap(
      htmlText.runs.first(where: { $0.text.contains("Keep") })?.style?.paragraph)
    XCTAssertGreaterThan(paragraph.firstLineHeadIndent, 0)
    XCTAssertGreaterThan(paragraph.headIndent, paragraph.firstLineHeadIndent)
  }

  func testHTMLInlineWrappersPreserveBreaksWithoutAddingMarkupOrSpaces() throws {
    let html = """
      <h2>Fixed <strong>rendering</strong>.</h2>
      <p><span>Fixed File</span><span>System.</span><b><br /></b><span>Fixed FileAPI.</span></p>
      <p>Fixed rendering.<strong></strong><em><br /></em><i></i>Kept line breaks.</p>
      """
    let content = try ReleaseNotesMarkup.attributedString(from: html, baseURL: nil).get()
    XCTAssertEqual(
      content.string.trimmingCharacters(in: .newlines),
      "Fixed rendering.\nFixed FileSystem.\nFixed FileAPI.\nFixed rendering.\nKept line breaks.")
  }

  func testReleaseSelectionIgnoresNavigationAndPreservesReleaseDate() throws {
    let html = """
      <nav><a href="/download/4.6">Moom 4.6 requires macOS</a></nav>
      <h2>Moom 4.6</h2><h3>August 19, 2026</h3>
      <h3>New Features</h3><ul><li>Added configurable window arrangements.</li></ul>
      <h2>Moom 4.5.1</h2><p>Older changes.</p>
      """
    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantChangelogText(
        fromHTML: html, version: "4.6.0",
        pageURL: URL(string: "https://manytricks.com/moom/releasenotes/")!,
        allowFirstSectionFallback: false))
    XCTAssertTrue(text.contains("August 19, 2026"))
    XCTAssertTrue(text.contains("Added configurable"))
    XCTAssertFalse(text.contains("Older changes"))
    XCTAssertFalse(text.contains("requires macOS"))
  }

  func testExactVersionsDoNotMatchAnotherPatchOrSuffix() {
    for (expected, wrong) in [("4.6.0", "4.4.6"), ("5.5.3", "5.5.1"), ("3.7.1beta1", "3.7.1")] {
      XCTAssertNil(
        ReleaseNotesMarkup.relevantText(
          from: "## Version \(wrong)\n\n- Fixed an important crash.", version: expected,
          allowFirstSectionFallback: false))
    }
  }

  func testColonVersionBoundaryAndLeadingDateAreKeptSeparate() throws {
    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantText(
        from: "0.98:\nFixed a crash.\n0.97:\nOld changes.", version: "0.98",
        allowFirstSectionFallback: false))
    XCTAssertFalse(text.contains("Old changes"))
    let dated = try XCTUnwrap(
      ReleaseNotesMarkup.relevantText(
        from:
          "version 14.2.1\nFixed unnecessary reconnections.\n2026 June 17\nversion 14.2.0\nOld changes.",
        version: "14.2.1", allowFirstSectionFallback: false))
    XCTAssertFalse(dated.contains("June"))
  }

  func testKnownLiveStubsAreRejected() {
    for text in [
      "Resolutionator 2.4 requires\nmacOS 10.9 Mavericks or newer. What’s new?\nRelease Notes\nWhat’s new in Resolutionator?",
      "Download A Better Finder Attributes 7.48\nfor Intel & Apple Silicon Macs, requires macOS 13.\nMore Options &gt;&gt;",
      "DBeaver Enterprise 26.2", "What's New in CLion 2026.2\nCLion\nDownload", "Moom 4.6 requires",
      "153.0.4234.32 (September 10, 2026)\nExtended Stable 152",
      "If you are not redirected automatically, follow this link.",
      "155.0.1\nFirefox for Android Release",
      "Conversation\nCommits 58\nChecks\nFiles changed\nMerged",
    ] {
      XCTAssertFalse(ReleaseNotesMarkup.isUsefulReleaseNotesText(text), text)
    }
    XCTAssertTrue(ReleaseNotesMarkup.isUsefulReleaseNotesText("Fixed a crash."))
    XCTAssertTrue(
      ReleaseNotesMarkup.isUsefulReleaseNotesText("Minor bug fixes and security enhancements."))
  }

  func testLocalizedReleaseNotesAreUsefulAndRenderWithoutEnglishWords() throws {
    for notes in [
      "แก้ไขปัญหาการเริ่มต้นแอปพลิเคชันและปรับปรุงความเสถียรของการซิงโครไนซ์",
      "修复了崩溃问题，改善了同步稳定性。", "修复崩溃问题",
      "クラッシュを修正し、同期の安定性を改善しました。",
      "충돌 문제를 수정하고 동기화 안정성을 개선했습니다.",
      "Исправлены сбои при запуске приложения и улучшена стабильность синхронизации.",
      "Оптимизирована производительность синхронизации.",
      "أصلحنا أعطال بدء التشغيل وحسّنا استقرار المزامنة.",
      "C++ parser",
    ] {
      XCTAssertTrue(ReleaseNotesMarkup.isUsefulReleaseNotesText(notes), notes)
      let rendered = try ReleaseNotesMarkup.attributedString(
        from: notes, baseURL: nil, relevantVersion: "2.0"
      ).get()
      XCTAssertTrue(rendered.string.contains(notes), notes)
    }
  }

  func testMacArticleWinsOverSameVersionOnOtherPlatforms() throws {
    let html = """
      <article class="visionos app"><h2>OmniPlan 4.11</h2><p>Fixed a Vision Pro crash.</p></article>
      <article class="mac app"><h2>OmniPlan 4.11</h2><p>Fixed a Mac document crash.</p></article>
      """
    let selected = try XCTUnwrap(
      ReleaseNotesMarkup.releaseContentHTML(
        fromHTML: html, version: "4.11",
        pageURL: URL(string: "https://www.omnigroup.com/releasenotes/omniplan")!))
    XCTAssertTrue(selected.contains("Mac document"))
    XCTAssertFalse(selected.contains("Vision Pro"))
  }

  func testFallbackDoesNotFollowPullRequestsOrDownloads() {
    for path in [
      "https://github.com/usebruno/bruno/pull/8734", "https://example.com/releases/app.dmg",
      "https://example.com/",
    ] {
      XCTAssertNil(
        ReleaseNotesMarkup.firstReleaseNotesURL(
          in: "<a href=\"\(path)\">Read more</a>", baseURL: nil))
    }
    XCTAssertNotNil(
      ReleaseNotesMarkup.firstReleaseNotesURL(
        in: "https://example.com/changelog/4.1.0", baseURL: nil))
  }

  func testMarkdownContainingHTMLDoesNotLoseReleaseBoundaries() throws {
    let markdown = """
      ## 4.90.0

      - Fixed a crash with <code>docker stop</code>.
      - Added support for another runtime.

      ## 4.89.0

      - Old change must not appear.
      """
    let text = try ReleaseNotesMarkup.attributedString(
      from: markdown, baseURL: URL(string: "https://docs.docker.com/desktop/release-notes.md"),
      relevantVersion: "4.90.0"
    ).get()
    XCTAssertTrue(text.string.contains("Fixed a crash"))
    XCTAssertFalse(text.string.contains("Old change"))
  }

  func testMarkdownReleaseNotesAreRenderedAsRichTextLists() throws {
    let markdown = """
      ## IINA 1.4.2

      ### New

      * * Added gapless audio playback options, #5433.
      * The system media keys are now configurable, #5933.
      """

    let string = try ReleaseNotesMarkup.attributedString(from: markdown, baseURL: nil).get()

    XCTAssertTrue(string.string.contains("IINA 1.4.2"))
    XCTAssertTrue(string.string.contains("Added gapless audio playback options"))
    XCTAssertFalse(string.string.contains("* Added"))
    XCTAssertFalse(string.string.contains("•        •"))
  }

  @MainActor
  func testOffMainReleaseNotesPreparationPreservesRenderedOutput() async throws {
    // The immutable rich-text reference includes heading, font, code, list and
    // relative-link semantics; plain-string equality would miss their loss.
    let markup =
      "<h2>Release 2.0</h2><p>Fixed <b>bold</b> and <i>italic</i> with <code>code</code>.</p><ol start=\"3\"><li>First</li><li><a href=\"notes\">Relative link</a></li></ol><script>ignored()</script><h2>Release 1.0</h2><p>Older release details.</p>"
    let preparedOffMain = try await ReleaseNotesMarkup.attributedStringByPreparingOffMain(
      from: markup,
      baseURL: URL(string: "https://example.com/releases/"), relevantVersion: "2.0"
    ).get()
    let reference = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/PreparedRichText/notes-2.html")
    XCTAssertEqual(
      ReleaseNotesWebDocument.html(for: preparedOffMain),
      try String(contentsOf: reference, encoding: .utf8))
  }

  func testMarkdownReleaseNotesStripFrontMatterAndInlineMarkup() throws {
    let markdown = """
      ---
      title: Ghostty 1.3.1
      description: |-
        Release notes for Ghostty 1.3.1, released on March 13, 2026.
      ---
      Ghostty 1.3.1 includes changes from
      **15 contributors** over **100 commits**. This is a patch release
      focused on fixing regressions introduced in 1.3.0, especially on macOS.
      **Highlights
      macOS Mouse Selection Bugs Fixed**
      PRs: GH-11276
      """

    let string = try ReleaseNotesMarkup.attributedString(
      from: markdown, baseURL: nil, relevantVersion: "1.3.1"
    ).get()

    XCTAssertTrue(string.string.contains("Ghostty 1.3.1 includes changes"))
    XCTAssertTrue(string.string.contains("15 contributors over 100 commits"))
    XCTAssertTrue(string.string.contains("macOS Mouse Selection Bugs Fixed"))
    XCTAssertFalse(string.string.contains("title:"))
    XCTAssertFalse(string.string.contains("description:"))
    XCTAssertFalse(string.string.contains("**"))
    XCTAssertFalse(string.string.contains("---"))

    let compactMarkdown =
      "--- title: Ghostty 1.3.1 description: |- Release notes for Ghostty 1.3.1, released on March 13, 2026. --- Ghostty 1.3.1 includes changes from **15 contributors** over **100 commits**. This is a patch release focused on fixing regressions introduced in 1.3.0."
    let compactString = try ReleaseNotesMarkup.attributedString(
      from: compactMarkdown, baseURL: nil, relevantVersion: "1.3.1"
    ).get()
    XCTAssertTrue(compactString.string.hasPrefix("Ghostty 1.3.1 includes changes"))
    XCTAssertFalse(compactString.string.contains("title:"))
    XCTAssertFalse(compactString.string.contains("---"))

    let missingOpeningDelimiterMarkdown = """
      title: Ghostty 1.3.1
      description: |-
      Release notes for Ghostty 1.3.1, released on March 13, 2026.
      ---
      Ghostty 1.3.1 includes changes from
      **15 contributors** over **100 commits**.
      """
    let missingOpeningString = try ReleaseNotesMarkup.attributedString(
      from: missingOpeningDelimiterMarkdown, baseURL: nil, relevantVersion: "1.3.1"
    ).get()
    XCTAssertTrue(missingOpeningString.string.hasPrefix("Ghostty 1.3.1 includes changes"))
    XCTAssertFalse(missingOpeningString.string.contains("description:"))
  }

  func testReleaseNotesMarkupKeepsOnlyRelevantVersionSection() throws {
    let changelog = """
      eqMac Changelog
      v1.8.15 - AirPods loop fix
      - Fixed AirPods causing eqMac to go into a device swap loop and freezing
      v1.8.14 - Device Routing fixes
      - Fixed Output Device routing issues introduced in v1.8.13
      """

    let string = try ReleaseNotesMarkup.attributedString(
      from: changelog, baseURL: nil, relevantVersion: "1.8.15"
    ).get()

    XCTAssertTrue(string.string.contains("AirPods loop fix"))
    XCTAssertFalse(string.string.contains("Device Routing fixes"))
  }

  func testReleaseNotesMarkupKeepsOnlyCurrentReleaseFromHTMLHistory() throws {
    let html = """
      <h2>AppCleaner 3.6.8 - 4 July, 2023</h2>
      <ul>
      \t<li>New app icon.</li>
      \t<li>Allow searching for related files of system apps.</li>
      </ul>
      <h2>AppCleaner 3.6.7 - 9 Dec, 2022</h2>
      <ul>
      \t<li>Fixed a bug causing SmartDelete to crash.</li>
      </ul>
      """

    let string = try ReleaseNotesMarkup.attributedString(
      from: html, baseURL: nil, relevantVersion: "3.6.8"
    ).get()

    XCTAssertTrue(string.string.contains("AppCleaner 3.6.8"))
    XCTAssertTrue(string.string.contains("New app icon"))
    XCTAssertFalse(string.string.contains("AppCleaner 3.6.7"))
    XCTAssertFalse(string.string.contains("SmartDelete"))
  }

  func testReleaseNotesMarkupRejectsVersionOnlyAndLinkOnlyText() throws {
    XCTAssertThrowsError(
      try ReleaseNotesMarkup.attributedString(
        from: "v3.4.2", baseURL: nil, relevantVersion: "3.4.2"
      ).get())
    XCTAssertThrowsError(
      try ReleaseNotesMarkup.attributedString(
        from:
          "<a href=\"https://example.com/details\">Details</a><br><a href=\"https://example.com/history\">Recent version history</a>",
        baseURL: nil, relevantVersion: "0.95"
      ).get())
    XCTAssertThrowsError(
      try ReleaseNotesMarkup.attributedString(
        from: "1.12.7 https://obsidian.md/changelog/2026-03-23-desktop-v1.12.7/", baseURL: nil,
        relevantVersion: "1.12.7"
      ).get())
  }

  func testReleaseNotesMarkupPreservesPlainTextChangelogLineBreaks() throws {
    let changelog = """
      3.6 May 29, 2026
      Auto-review Run Mode
      Auto-review is a new run mode that allows Cursor to work for longer.
      Configure your run mode in Settings > Cursor Settings > Agents > Run Mode.
      3.5 May 20, 2026
      Shared Canvases
      """

    let string = try ReleaseNotesMarkup.attributedString(
      from: changelog, baseURL: nil, relevantVersion: "3.6"
    ).get()

    XCTAssertTrue(string.string.contains("3.6 May 29, 2026\nAuto-review Run Mode"))
    XCTAssertFalse(string.string.contains("3.5 May 20, 2026"))
  }

  func testReleaseNotesMarkupSeparatesCompactedSparkleChangelogText() throws {
    let changelog =
      "3.6 May 29, 2026 · Changelog Auto-review Run Mode Auto-review is a new run mode that allows Cursor to work for longer with fewer approval prompts and safer execution. Configure your run mode in Settings > Cursor Settings > Agents > Run Mode."

    let string = try ReleaseNotesMarkup.attributedString(
      from: changelog, baseURL: nil, relevantVersion: "3.6"
    ).get()

    XCTAssertTrue(
      string.string.contains(
        "3.6 May 29, 2026 · Changelog\nAuto-review Run Mode\nAuto-review is a new run mode"))
  }

  func testReleaseNotesMarkupDeduplicatesRepeatedLeadingVersionTitle() throws {
    let markdown = """
      IINA 1.4.3
      IINA 1.4.3
      IINA 1.4.3 fixes important security issues and regressions.
      Bug Fixes
      - Fix a security issue.
      """

    let string = try ReleaseNotesMarkup.attributedString(
      from: markdown, baseURL: nil, relevantVersion: "1.4.3"
    ).get()

    XCTAssertFalse(string.string.contains("IINA 1.4.3\nIINA 1.4.3\nIINA 1.4.3 fixes"))
    XCTAssertTrue(
      string.string.contains("IINA 1.4.3\nFixes important security issues and regressions."))
  }

  func testReleaseNotesMarkupRejectsNavigationPageNoise() throws {
    let html = """
      <html><head><title>The AI workspace that works for you. | Notion Product</title></head>
      <body>
      <nav>Notion Your AI workspace</nav>
      <p>-</p><p>Notion Calendar</p><p>-</p><p>Notion Mail</p><p>-</p>
      <p>Notion AI AI tools for work</p><p>-</p>
      <p>Agents Automate busywork</p><p>-</p>
      <p>AI Meeting Notes Perfectly written by AI</p><p>-</p>
      <p>Enterprise Search Find answers instantly</p><p>-</p>
      <p>Knowledge Base Centralize your knowledge</p><p>-</p>
      <p>Docs Simple and powerful</p><p>-</p>
      <p>Projects Manage any project</p>
      </body></html>
      """

    XCTAssertThrowsError(
      try ReleaseNotesMarkup.attributedString(
        from: html, baseURL: URL(string: "https://www.notion.so/product")!, relevantVersion: "7.19"
      ).get())
  }

  func testReleaseNotesMarkupRejectsMojibakeText() throws {
    let gibberish = """
      Ñù¢x¿ëÆIw±¥ûs]z|².6 ç°^éÉ"st0Æñqd7wßZú¼üä,õ0!GéØ9cL=x16ãè³Ø´ÙÀ è på°7ÆgÝ².4,±ø}¿ õù±¯¾üiàpípjòÎ½c Ëp¾;µ¼,á{ÝVyÃ(ä¤Ç¶xs´i;»||
      ³HxåÿXèÕõ%ÍÁ÷9 óke  ˜&ó¼öU#êÒùñÛà¸}Òäwö¦¾¶Ex2EöòËÕÿÚüæ8Å/xÜcDøþéõ@ãÚ
      """

    XCTAssertThrowsError(
      try ReleaseNotesMarkup.attributedString(
        from: gibberish, baseURL: nil, relevantVersion: "5.80.6"
      ).get())
  }

  func testReleaseNotesMarkupKeepsShortControlTextBelowMojibakeThreshold() {
    let shortControlText = String(repeating: "\u{1}", count: 20)

    XCTAssertFalse(ReleaseNotesMarkup.looksLikeBinaryOrMojibakeText(shortControlText))
  }

  func testReleaseNotesMarkupSeparatesHTMLChangelogHeadings() throws {
    let html = """
      <a href="/changelog/3-6">3.6 May 29, 2026</a> · <a href="/changelog">Changelog</a><h1>Auto-review Run Mode</h1>
      <p>Auto-review is a new run mode that allows Cursor to work for longer.</p>
      <a href="/changelog/3-5">3.5 May 20, 2026</a><h1>Shared Canvases</h1>
      """

    let string = try ReleaseNotesMarkup.attributedString(
      from: html, baseURL: URL(string: "https://cursor.com/changelog")!, relevantVersion: "3.6"
    ).get()

    XCTAssertTrue(string.string.contains("Changelog\nAuto-review Run Mode"))
    XCTAssertFalse(string.string.contains("Shared Canvases"))
  }

  func testReleaseNotesMarkupUsesCursorVersionHeadingBeforeBodyMention() throws {
    let changelog = """
      Changelog
      Jun 10, 2026
      Bugbot is now over 3x faster
      Available in Cursor 3.7+ and on cursor.com/agents.
      3.7 Jun 5, 2026
      Design Mode Improvements
      With Design Mode in the Cursor browser, you can click, draw, or describe changes by voice.
      3.6 May 29, 2026
      Auto-review Run Mode
      Auto-review is a new run mode that allows Cursor to work for longer.
      """

    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantText(
        from: changelog, version: "3.7", allowFirstSectionFallback: true))

    XCTAssertTrue(text.hasPrefix("3.7 Jun 5, 2026"))
    XCTAssertTrue(text.contains("Design Mode Improvements"))
    XCTAssertFalse(text.contains("Available in Cursor 3.7+"))
    XCTAssertFalse(text.contains("Auto-review Run Mode"))
  }

  func testReleaseNotesMarkupStopsCursorSectionAtNextDatedEntry() throws {
    let changelog = """
      3.7 Jun 5, 2026 · Changelog
      Design Mode Improvements
      With Design Mode in the Cursor browser, you can click, draw, or describe changes by voice.
      Jun 4, 2026 · Changelog
      Custom agent modes
      Custom agent modes let you define reusable instruction sets.
      Jun 3, 2026 · Changelog
      Background agents
      """

    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantText(
        from: changelog, version: "3.7", allowFirstSectionFallback: true))

    XCTAssertTrue(text.hasPrefix("3.7 Jun 5, 2026"))
    XCTAssertTrue(text.contains("Design Mode Improvements"))
    XCTAssertFalse(text.contains("Custom agent modes"))
    XCTAssertFalse(text.contains("Background agents"))
  }

  func testReleaseNotesMarkupExtractsFirstReleaseNotesURLFromStubText() throws {
    let text = "1.12.7 https://obsidian.md/changelog/2026-03-23-desktop-v1.12.7/"
    let url = try XCTUnwrap(ReleaseNotesMarkup.firstReleaseNotesURL(in: text, baseURL: nil))

    XCTAssertEqual(url.absoluteString, "https://obsidian.md/changelog/2026-03-23-desktop-v1.12.7/")
  }

  func testReleaseNotesMarkupExtractsChromeDesktopReleaseFromBlog() throws {
    let html = """
      <h2>Chrome for Android Update</h2>
      <p>Thursday, June 11, 2026</p>
      <p>Chrome 149 (149.0.7827.114) for Android is available.</p>
      <h2>Stable Channel Update for Desktop</h2>
      <p>Thursday, June 11, 2026</p>
      <p>The Stable channel has been updated to 149.0.7827.114/.115 for Windows and Mac and 149.0.7827.114 for Linux, which will roll out over the coming days/weeks.</p>
      <p>Security Fixes and Rewards</p>
      <p>This update includes 28 security fixes.</p>
      <p>Critical CVE-2026-12007: Use after free in Core.</p>
      <p>Google Chrome</p>
      <h2>Extended Stable Updates for Desktop</h2>
      <p>The Extended Stable channel has been updated to 148.0.7778.265 for Windows and Mac.</p>
      """

    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantChangelogText(
        fromHTML: html,
        version: "149.0.7827.115",
        pageURL: URL(string: "https://chromereleases.googleblog.com/")!,
        allowFirstSectionFallback: false
      ))

    XCTAssertTrue(text.contains("Stable channel has been updated"))
    XCTAssertTrue(text.contains("28 security fixes"))
    XCTAssertFalse(text.contains("Android is available"))
    XCTAssertFalse(text.contains("Extended Stable channel"))
  }

  func testReleaseNotesMarkupExtractsNavicatMacReleaseInsteadOfWindows() throws {
    let html = """
      <h2>Navicat Premium (Windows) version 17.3.12</h2>
      <p>Fixed a Windows-only credential manager issue.</p>
      <h2>Navicat Premium (macOS) version 17.3.12</h2>
      <ul><li>Added native support for the latest macOS database driver.</li><li>Improved sidebar responsiveness.</li></ul>
      <h2>Navicat Premium (Linux) version 17.3.12</h2>
      <p>Fixed a Linux package installation issue.</p>
      """

    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantChangelogText(
        fromHTML: html,
        version: "17.3.12",
        pageURL: URL(string: "https://www.navicat.com/en/products/navicat-premium-release-note")!,
        allowFirstSectionFallback: false
      ))

    XCTAssertTrue(text.contains("Navicat Premium (macOS) version 17.3.12"))
    XCTAssertTrue(text.contains("native support"))
    XCTAssertFalse(text.contains("Windows-only"))
    XCTAssertFalse(text.contains("Linux package"))
  }

  func testReleaseNotesMarkupExtractsChromeDesktopReleaseFromBloggerTemplate() throws {
    let html = """
      <div class='post'>
      <h2 class='title'>Chrome for Android Update</h2>
      <div class='post-content'>
      <script type='text/template'>
      <p>Chrome 149 (149.0.7827.114) for Android is available.</p>
      <div>Android releases contain the same security fixes as their corresponding <a href="https://chromereleases.googleblog.com/2026/06/stable-channel-update-for-desktop.html">Desktop releases</a> (Windows &amp; Mac: 149.0.7827.114/115, Linux: 149.0.7872.114) unless otherwise noted.</div>
      </script>
      </div>
      </div>
      <div class='post'>
      <h2 class='title'>Stable Channel Update for Desktop</h2>
      <div class='post-content'>
      <script type='text/template'>
      <p><span>The Stable channel has been updated to 149.0.7827.114/.115 for Windows and Mac and 149.0.7827.114 for Linux, which will roll out over the coming days/weeks.</span></p>
      <h1><span>Security Fixes and Rewards</span></h1>
      <p>This update includes 28 security fixes.</p>
      <p>[N/A][<a href="https://issues.chromium.org/issues/534994449">534994449</a>] Critical CVE-2026-12007: Use after free in Core. Reported by @_3P1C.</p>
      <p>[TBD][560238696] Critical CVE-2026-12008: Use after free in Browser. Reported by @lbherrera_.</p>
      </script>
      </div>
      </div>
      <div class='post'>
      <h2 class='title'>Stable Channel Update for Desktop</h2>
      <script type='text/template'>
      <p>The Stable channel has been updated to 148.0.7778.265 for Windows and Mac.</p>
      <p>Older release with unrelated fixes.</p>
      </script>
      </div>
      """

    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantChangelogText(
        fromHTML: html,
        version: "149.0.7827.115",
        pageURL: URL(string: "https://chromereleases.googleblog.com/")!,
        allowFirstSectionFallback: false
      ))

    XCTAssertTrue(text.contains("Stable Channel Update for Desktop"))
    XCTAssertTrue(text.contains("28 security fixes"))
    XCTAssertFalse(text.contains("Android releases contain"))
    let content = try ReleaseNotesMarkup.attributedString(
      from: text, baseURL: URL(string: "https://chromereleases.googleblog.com/")!
    ).get()
    let lines = content.string.components(separatedBy: .newlines)
    XCTAssertEqual(lines.first, "Stable Channel Update for Desktop")
    XCTAssertTrue(lines.contains("Security Fixes and Rewards"))
    XCTAssertTrue(lines.contains("This update includes 28 security fixes."))
    XCTAssertTrue(lines.contains { $0.hasPrefix("[N/A]") && $0.hasSuffix("@_3P1C.") })
    XCTAssertTrue(lines.contains { $0.hasPrefix("[TBD]") && $0.hasSuffix("@lbherrera_.") })
    XCTAssertTrue(
      content.runs.contains {
        $0.text.contains("Security Fixes and Rewards") && $0.style?.bold == true
      })
    XCTAssertEqual(
      content.runs.first { $0.text == "534994449" }?.link,
      URL(string: "https://issues.chromium.org/issues/534994449"))
    XCTAssertFalse(content.string.contains("Older release"))
  }

  func testReleaseNotesMarkupExtractsZedReleaseWithoutNavigationChrome() throws {
    let html = """
      <article>
      <p>Versions</p>
      <p>1.6.3</p>
      <p>1.5.5</p>
      <p>Version : 1.6.3</p>
      <p>Platform : macOS</p>
      <p>Trusted by world-class developers and industry leading teams</p>
      <h1>1.6.3</h1>
      <p>Jun 10, 2026</p>
      <p>macOS</p>
      <p>Loading...</p>
      <p>Windows</p>
      <p>Loading...</p>
      <p>Linux</p>
      <p>Loading...</p>
      <p>This week's release includes the ability to open a Git diff for a single file in its own dedicated tab from the Git panel.</p>
      <h2>Features</h2>
      <h3>AI</h3>
      <ul><li>Agent: Added a way to share skills via links.</li></ul>
      </article>
      """

    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantChangelogText(
        fromHTML: html,
        version: "1.6.3",
        pageURL: URL(string: "https://zed.dev/releases/stable/1.6.3")!,
        allowFirstSectionFallback: false
      ))

    XCTAssertTrue(text.hasPrefix("1.6.3"))
    XCTAssertTrue(text.contains("This week's release includes"))
    XCTAssertTrue(text.contains("Agent: Added a way to share skills via links."))
    XCTAssertFalse(text.contains("Trusted by world-class developers"))
    XCTAssertFalse(text.contains("Version :"))
    XCTAssertFalse(text.contains("Loading"))
  }

  func testReleaseNotesMarkupExtractsZoomReleaseSectionWithoutVersionMatrix() throws {
    let html = """
      <article>
      <h1>Release notes for the Zoom Workplace app</h1>
      <h2>Released</h2>
      <h3>May 18, 2026</h3>
      <p>Note: This release was originally scheduled for May 11, but was delayed by one week.</p>
      <h4>Full versions</h4>
      <p>Windows</p><p>macOS</p><p>Linux</p><p>Android*</p>
      <p>7.0.5 (38856)</p><p>7.0.5 (81138)</p><p>7.0.5 (3034)</p><p>7.0.5 (40164)</p>
      <p>*The mobile releases require additional approval from their respective app stores.</p>
      <h4>New, enhanced, and changed features</h4>
      <p>Type Feature title Description Platforms</p>
      <p>General features</p>
      <p>New or enhanced feature Show or hide icon labels in the navigation bar Users can hide text labels on navigation bar app icons.</p>
      <p>Windows</p><p>macOS</p><p>Linux</p>
      <p>New or enhanced feature Support automatic sign-in when joining a meeting from a web browser Users who are signed into the Zoom web portal can be signed into the app during join flow.</p>
      <p>Windows</p><p>macOS</p><p>Linux</p>
      <h3>April 29, 2026</h3>
      <p>Older release details.</p>
      </article>
      """

    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantChangelogText(
        fromHTML: html,
        version: "7.0.5",
        pageURL: URL(
          string: "https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0061222")!,
        allowFirstSectionFallback: false
      ))

    XCTAssertTrue(text.hasPrefix("Zoom 7.0.5"))
    XCTAssertTrue(text.contains("May 18, 2026"))
    XCTAssertTrue(text.contains("Show or hide icon labels"))
    XCTAssertTrue(text.contains("Support automatic sign-in"))
    XCTAssertFalse(text.contains("Full versions"))
    XCTAssertFalse(text.contains("7.0.5 (38856)"))
    XCTAssertFalse(text.contains("Type Feature title Description Platforms"))
    XCTAssertFalse(text.contains("Older release details"))
  }

  func testReleaseNotesMarkupExtractsZoomReleaseSectionFromStructuredArticleBody() throws {
    let articleBody = """
      <p>Zoom provides up-to-date release notes for the Zoom Workplace app.</p>
      <h2>Released</h2>
      <h3>May 18, 2026</h3>
      <p><strong>Note</strong>: This release was originally scheduled for May 11, but was delayed by one week.</p>
      <h4>Full versions</h4>
      <article>
      <table><thead><tr><th>Windows</th><th>macOS</th><th>Linux</th><th>Android*</th></tr></thead>
      <tbody><tr><td>7.0.5 (38856)</td><td>7.0.5 (81138)</td><td>7.0.5 (3034)</td><td>7.0.5 (40164)</td></tr></tbody></table>
      </article>
      <p>*The mobile releases require additional approval from their respective app stores.</p>
      <h4>New, enhanced, and changed features</h4>
      <table><thead><tr><th>Type</th><th>Feature title</th><th>Description</th><th>Platforms</th></tr></thead>
      <tbody><tr><td>New or enhanced feature</td><td>Show or hide icon labels in the navigation bar</td><td>Users can hide text labels on navigation bar app icons in the Zoom Workplace desktop app.</td><td>Windows <br />macOS <br />Linux</td></tr></tbody></table>
      <h4>Resolved issues</h4>
      <table><tbody><tr><td>Minor bug fixes</td><td>Windows <br />macOS <br />Linux</td></tr></tbody></table>
      <h3>April 29, 2026</h3>
      <p>Older release details.</p>
      """
    let jsonData = try JSONSerialization.data(withJSONObject: [
      "@context": "https://schema.org",
      "@type": "TechArticle",
      "articleBody": articleBody,
    ])
    let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
    let html = """
      <html>
      <head><script type="application/ld+json">\(json)</script></head>
      <body>
      <p>Windows</p><p>macOS</p><p>Linux</p><p>Android*</p>
      <p>7.0.5 (38856)</p><p>7.0.5 (81138)</p><p>7.0.5 (3034)</p><p>7.0.5 (40164)</p>
      </body>
      </html>
      """

    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantChangelogText(
        fromHTML: html,
        version: "7.0.5",
        pageURL: URL(
          string: "https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0061222")!,
        allowFirstSectionFallback: false
      ))

    XCTAssertTrue(text.hasPrefix("Zoom 7.0.5"))
    XCTAssertTrue(text.contains("May 18, 2026"))
    XCTAssertTrue(text.contains("Show or hide icon labels"))
    XCTAssertTrue(text.contains("Minor bug fixes"))
    XCTAssertFalse(text.contains("7.0.5 (38856)"))
    XCTAssertFalse(text.contains("Older release details"))

    let renderedText = try ReleaseNotesMarkup.attributedString(
      from: text,
      baseURL: URL(
        string: "https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0061222")!,
      relevantVersion: "7.0.5"
    ).get().string
    XCTAssertTrue(renderedText.contains("Show or hide icon labels"))
    XCTAssertTrue(renderedText.contains("Minor bug fixes"))
  }
  func testReleaseNotesMarkupExtractsVersionedArticleFrom1PasswordPage() throws {
    let html = """
      <section class="c-updates">
      \t<article class="c-updates__release">
      \t\t<header>
      \t\t\t<time>June 2 2026</time>
      \t\t\t<h6>1Password for Mac 8.12.22</h6>
      \t\t</header>
      \t\t<div class="c-updates__content">
      \t\t\t<ul>
      \t\t\t\t<li>We&rsquo;ve improved the scrolling experience to better match typical macOS scrolling behavior.</li>
      \t\t\t</ul>
      \t\t</div>
      \t</article>
      \t<article class="c-updates__release">
      \t\t<header>
      \t\t\t<time>May 20 2026</time>
      \t\t\t<h6>1Password for Mac 8.12.21</h6>
      \t\t</header>
      \t\t<div class="c-updates__content">
      \t\t\t<ul><li>Older release notes should not be included.</li></ul>
      \t\t</div>
      \t</article>
      </section>
      """

    let article = try XCTUnwrap(
      ReleaseNotesMarkup.releaseContentHTML(
        fromHTML: html,
        version: "8.12.22",
        pageURL: URL(string: "https://releases.1password.com/mac/stable/")!
      ))
    let string = try ReleaseNotesMarkup.attributedString(
      from: article,
      baseURL: URL(string: "https://releases.1password.com/mac/stable/")!,
      relevantVersion: "8.12.22"
    ).get()

    XCTAssertTrue(string.string.contains("1Password for Mac 8.12.22"))
    XCTAssertTrue(string.string.contains("improved the scrolling experience"))
    XCTAssertFalse(string.string.contains("Older release notes"))
  }

  func testReleaseNotesMarkupPrefersObsidianDesktopChangelogLink() throws {
    let html = """
      <a href="/changelog/2026-03-23-mobile-v1.12.7/">1.12.7 Mobile</a>
      <p>Includes all new features and bug fixes up to <a href="/changelog/2026-03-23-desktop-v1.12.7/">Obsidian Desktop v1.12.7</a>.</p>
      <a href="/changelog/2026-03-23-desktop-v1.12.7/">1.12.7 Desktop</a>
      """

    let url = try XCTUnwrap(
      ReleaseNotesMarkup.linkedChangelogURL(
        fromHTML: html,
        version: "1.12.7",
        pageURL: URL(string: "https://obsidian.md/changelog/")!
      ))

    XCTAssertEqual(url.absoluteString, "https://obsidian.md/changelog/2026-03-23-desktop-v1.12.7/")
  }

  func testReleaseNotesMarkupPrefersObsidianDesktopArticle() throws {
    let html = """
      <article>
      \t<h2>1.12.7 Mobile</h2>
      \t<p>Includes all new features and bug fixes up to Obsidian Desktop v1.12.7.</p>
      </article>
      <article>
      \t<h2>1.12.7 Desktop</h2>
      \t<h3>Improvements</h3>
      \t<p>The Obsidian Installer is now bundled with a new binary file for using the CLI.</p>
      </article>
      """

    let article = try XCTUnwrap(
      ReleaseNotesMarkup.releaseContentHTML(
        fromHTML: html,
        version: "1.12.7",
        pageURL: URL(string: "https://obsidian.md/changelog/")!
      ))
    let string = try ReleaseNotesMarkup.attributedString(
      from: article,
      baseURL: URL(string: "https://obsidian.md/changelog/")!,
      relevantVersion: "1.12.7"
    ).get()

    XCTAssertTrue(string.string.contains("1.12.7 Desktop"))
    XCTAssertTrue(string.string.contains("Obsidian Installer"))
    XCTAssertFalse(string.string.contains("1.12.7 Mobile"))
  }

  func testReleaseNotesMarkupPrefersObsidianDesktopPlainTextSection() throws {
    let text = """
      Changelog
      June 9, 2026
      1.13.1 Mobile
      Includes all new features and bug fixes up to Obsidian Desktop v1.13.1.
      Improvements
      - Settings pages now have enough padding to scroll fully into view.
      June 9, 2026
      1.13.1 Desktop
      Improvements
      - Sliders now show a permanent label with the current value.
      No longer broken
      - Fixed choppy horizontal scrolling when sidebar tabs overflow.
      May 28, 2026
      1.13.0 Desktop
      Older notes should not be included.
      """

    let relevantText = try XCTUnwrap(
      ReleaseNotesMarkup.relevantChangelogText(
        fromHTML: text,
        version: "1.13.1",
        pageURL: URL(string: "https://obsidian.md/changelog/")!,
        allowFirstSectionFallback: false
      ))

    XCTAssertTrue(relevantText.contains("1.13.1 Desktop"))
    XCTAssertTrue(relevantText.contains("Sliders now show"))
    XCTAssertFalse(relevantText.contains("1.13.1 Mobile"))
    XCTAssertFalse(relevantText.contains("Older notes"))
  }

  func testReleaseNotesMarkupDoesNotUseObsidianIndexTypesetAsRelease() throws {
    let html = """
      <div class="typeset">
      \t<h2>1.13.1 Mobile</h2>
      \t<p>Includes all new features and bug fixes up to Obsidian Desktop v1.13.1.</p>
      \t<h2>1.13.1 Desktop</h2>
      \t<p>Sliders now show a permanent label with the current value.</p>
      </div>
      """

    XCTAssertNil(
      ReleaseNotesMarkup.releaseContentHTML(
        fromHTML: html,
        version: "1.13.1",
        pageURL: URL(string: "https://obsidian.md/changelog/")!
      ))

    XCTAssertNotNil(
      ReleaseNotesMarkup.releaseContentHTML(
        fromHTML: html,
        version: "1.13.1",
        pageURL: URL(string: "https://obsidian.md/changelog/2026-06-09-desktop-v1.13.1/")!
      ))
  }

  func testReleaseNotesMarkupExtractsFirstSectionFromVersionlessChangelog() throws {
    let changelog = """
      Changelog
      May 13, 2026
      Development environments for cloud agents
      Agents can now configure environments.
      May 11, 2026
      Cursor in Microsoft Teams
      """

    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantText(
        from: changelog, version: "3.4", allowFirstSectionFallback: true))

    XCTAssertTrue(text.contains("Development environments"))
    XCTAssertFalse(text.contains("Cursor in Microsoft Teams"))
  }

  func testReleaseNotesMarkupSkipsVersionNavigationWhenFindingRelevantSection() throws {
    let changelog = """
      Versions
      • 1.4.4 • 1.4.3 • 1.4.2 • 1.3.7 • 1.3.6 • 1.3.5
      May 2026
      1.4.4
      May 28, 2026
      macOS
      - Fixed an issue where using GPT models would return an error.
      1.4.3
      May 28, 2026
      - Fixed GitHub Copilot Chat showing an empty model dropdown.
      """

    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantText(
        from: changelog, version: "1.4.4", allowFirstSectionFallback: false))

    XCTAssertFalse(text.contains("1.4.3 • 1.4.2"))
    XCTAssertTrue(text.contains("Fixed an issue where using GPT models"))
    XCTAssertFalse(text.contains("empty model dropdown"))
  }

  func testReleaseNotesMarkupSkipsZedVersionSidebarList() throws {
    let html = """
      <nav>
      \t<h2>Versions</h2>
      \t<a href="/releases/stable/1.6.3">1.6.3</a>
      \t<a href="/releases/stable/1.5.5">1.5.5</a>
      \t<a href="/releases/stable/1.5.4">1.5.4</a>
      \t<h2>Versions</h2>
      \t<a href="/releases/stable/1.6.3">1.6.3</a>
      \t<a href="/releases/stable/1.5.5">1.5.5</a>
      \t<a href="/releases/stable/1.5.4">1.5.4</a>
      </nav>
      <main>
      \t<h2>June 2026</h2>
      \t<p>* * *</p>
      \t<h2>1.6.3</h2>
      \t<p>Jun 10, 2026</p>
      \t<p>macOS</p>
      \t<p>Loading…</p>
      \t<p>Windows</p>
      \t<p>Loading...</p>
      \t<p>Linux</p>
      \t<p>This week's release includes the ability to open a Git diff for a single file.</p>
      \t<h3>Features</h3>
      \t<ul>
      \t\t<li>Agent: Added a way to share skills via links.</li>
      \t</ul>
      \t<h2>1.5.5</h2>
      \t<p>Jun 09, 2026</p>
      \t<ul>
      \t\t<li>Older release note.</li>
      \t</ul>
      </main>
      """

    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantChangelogText(
        fromHTML: html, version: "1.6.3",
        pageURL: URL(string: "https://zed.dev/releases/stable/1.6.3")!,
        allowFirstSectionFallback: false))

    XCTAssertTrue(text.hasPrefix("1.6.3"))
    XCTAssertTrue(text.contains("This week's release includes"))
    XCTAssertTrue(text.contains("Agent: Added a way to share skills"))
    XCTAssertFalse(text.contains("Versions"))
    XCTAssertFalse(text.contains("Loading"))
    XCTAssertFalse(text.contains("Older release note"))
  }

  func testReleaseNotesMarkupExtractsZedReleasePayloadBeforeVersionNavigation() throws {
    let html = """
      <div>Versions</div>
      <a href="/releases/stable/1.4.4">1.4.4</a>
      <a href="/releases/stable/1.4.3">1.4.3</a>
      <script>self.__next_f.push([1,"[[\\"$\\",\\"$L105\\",\\"Zed-aarch64.dmg\\",{\\"release\\":{\\"version\\":\\"1.4.4\\",\\"description\\":\\"- copilot: Fixed an issue where using GPT models would return an error in `invalid_request_body` ([#57979](https://github.com/zed-industries/zed/pull/57979))\\\\r\\\\n\\\\r\\\\n\\",\\"assets\\":[\\"Zed-aarch64.dmg\\"],\\"published_at\\":\\"2026-05-28T20:55:02.000Z\\",\\"channelType\\":\\"stable\\",\\"isLatest\\":true},\\"asset\\":\\"Zed-aarch64.dmg\\"}]]"])</script>
      """

    let text = try XCTUnwrap(
      ZedReleaseNotesExtractor.zedReleaseText(
        fromHTML: html, version: "1.4.4",
        pageURL: URL(string: "https://zed.dev/releases/stable/1.4.4")!))

    XCTAssertTrue(text.contains("invalid_request_body"))
    XCTAssertFalse(text.contains(#"\r"#))
    XCTAssertFalse(text.contains(#"\n"#))
    XCTAssertFalse(text.contains("1.4.3"))
    XCTAssertFalse(text.contains("Versions"))
  }

  func testReleaseNotesMarkupIgnoresZedReactServerDescriptionReference() throws {
    let html = """
      <script>self.__next_f.push([1,"[[\\"$\\",\\"$L105\\",\\"Zed-aarch64.dmg\\",{\\"release\\":{\\"version\\":\\"1.6.3\\",\\"description\\":\\"$106\\",\\"assets\\":[\\"Zed-aarch64.dmg\\"],\\"published_at\\":\\"2026-06-10T18:33:08.000Z\\",\\"channelType\\":\\"stable\\",\\"isLatest\\":true},\\"asset\\":\\"Zed-aarch64.dmg\\"}]]"])</script>
      <main>
      \t<p>Version : 1.6.3</p>
      \t<p>Platform : macOS</p>
      \t<p>Trusted by world-class developers and industry leading teams</p>
      </main>
      <script>self.__next_f.push([1,"106:T4b60,"])</script>
      <script>self.__next_f.push([1,"This week's release includes the ability to open a Git diff for a single file.\\r\\n\\r\\n## Features\\r\\n\\r\\n- Agent: Added a way to share skills via links.\\r\\n"])</script>
      """

    let text = try XCTUnwrap(
      ZedReleaseNotesExtractor.zedReleaseText(
        fromHTML: html, version: "1.6.3",
        pageURL: URL(string: "https://zed.dev/releases/stable/1.6.3")!))

    XCTAssertTrue(text.hasPrefix("This week's release"))
    XCTAssertTrue(text.contains("Agent: Added a way to share skills"))
    XCTAssertFalse(text.contains("$106"))
    XCTAssertFalse(text.contains("Version : 1.6.3"))
  }

  func testReleaseNotesMarkupExtractsRelevantSectionFromHTMLWithoutRendering() throws {
    let html = """
      <html>
      <head>
      \t<script>window.versions = ["1.4.3"];</script>
      </head>
      <body>
      \t<h2>1.4.4</h2>
      \t<p>Fixed &amp; improved<br>Added &#33; support</p>
      \t<h2>1.4.3</h2>
      \t<p>Previous release</p>
      </body>
      </html>
      """

    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantChangelogText(
        fromHTML: html, version: "1.4.4", pageURL: URL(string: "https://example.com/changelog")!,
        allowFirstSectionFallback: false))

    XCTAssertTrue(text.contains("Fixed & improved"))
    XCTAssertTrue(text.contains("Added ! support"))
    XCTAssertFalse(text.contains("Previous release"))
    XCTAssertFalse(text.contains("window.versions"))
  }

}
