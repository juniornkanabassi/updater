// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import XCTest

@testable import Latest

final class ReleaseNotesWebDocumentTest: XCTestCase {
  func testReleaseNotesWebDocumentEscapesMarkupAndRejectsScriptLinks() {
    let text = NSMutableAttributedString(string: "<script>alert('x')</script> & notes")
    text.addAttribute(.link, value: "javascript:alert(1)", range: NSRange(location: 0, length: 8))
    let html = ReleaseNotesWebDocument.html(for: ReleaseNotesLegacyBridge.content(from: text))
    XCTAssertTrue(html.contains("&lt;script&gt;"))
    XCTAssertFalse(html.contains("<script>"))
    XCTAssertFalse(html.contains("href=\"javascript:"))
    XCTAssertTrue(html.contains("default-src 'none'"))
  }

  func testReleaseNotesSerializationPreservesUnicodeAndSharesLinkPolicy() {
    let source = ReleaseNotesContent(string: "<&>\"\t👩🏽‍💻 e\u{301} 中文")
    let html = ReleaseNotesWebDocument.html(for: source)
    XCTAssertTrue(html.contains("&lt;&amp;&gt;&quot; 👩🏽‍💻 e\u{301} 中文"))
    for scheme in ["https", "http", "mailto"] {
      let link = "\(scheme):example.com"
      XCTAssertEqual(ReleaseNotesWebDocument.externalURL(link)?.absoluteString, link)
      XCTAssertEqual(ReleaseNotesWebDocument.externalURL(URL(string: link))?.absoluteString, link)
    }
    for link in ["javascript:alert(1)", "file:///etc/hosts", "data:text/html,test", "/relative"] {
      XCTAssertNil(ReleaseNotesWebDocument.externalURL(link))
    }
    XCTAssertNil(ReleaseNotesWebDocument.externalURL(nil))
  }
}
