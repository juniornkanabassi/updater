// Copyright © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Foundation

/// Read-only compatibility for existing RTF caches and non-UTF8 vendor notes.
/// Newly prepared content and cache writes use semantic runs without AppKit.
enum ReleaseNotesLegacyBridge {
  static func content(from text: NSAttributedString) -> ReleaseNotesContent {
    let plainText = text.string as NSString
    var runs: [ReleaseNotesContent.Run] = []
    text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) {
      attributes, range, _ in
      let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
      let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle).map {
        ReleaseNotesStyle.Paragraph(
          spacing: $0.paragraphSpacing, spacingBefore: $0.paragraphSpacingBefore,
          headIndent: $0.headIndent, firstLineHeadIndent: $0.firstLineHeadIndent)
      }
      let style = ReleaseNotesStyle(
        bold: traits.contains(.bold), italic: traits.contains(.italic),
        monospaced: traits.contains(.monoSpace),
        strikethrough: (attributes[.strikethroughStyle] as? Int ?? 0) != 0,
        paragraph: paragraph)
      let link: URL?
      switch attributes[.link] {
      case let url as URL: link = url
      case let string as String: link = URL(string: string)
      default: link = nil
      }
      runs.append(.init(text: plainText.substring(with: range), style: style, link: link))
    }
    return ReleaseNotesContent(runs: runs)
  }

  /// Retains Foundation's legacy encoding detection for non-UTF8 vendor notes.
  static func decode(_ data: Data) throws -> ReleaseNotesContent {
    var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
      .documentType: NSAttributedString.DocumentType.html
    ]
    let text = try NSAttributedString(data: data, options: options, documentAttributes: nil)
    if text.string.split(separator: "\n").count == 1 {
      options[.documentType] = NSAttributedString.DocumentType.plain
      return content(
        from: try NSAttributedString(data: data, options: options, documentAttributes: nil))
    }
    return content(from: text)
  }

  static func decodeRTF(_ data: Data) throws -> ReleaseNotesContent {
    content(
      from: try NSAttributedString(
        data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil))
  }
}
