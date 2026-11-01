// Copyright © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import SwiftUI

/// A shared semantic input for HTML, Markdown and plain-text release notes.
/// Foundation parses Markdown inline/block intents; vendor CSS never reaches the view.
enum ReleaseNotesDocument {
  static func markdown(fromHTML html: String, baseURL: URL? = nil) -> String? {
    guard html.containsHTMLTag else { return html }
    let cleaned = ReleaseNotesMarkup.replacingMatches(
      in: html, matching: ReleaseNotesMarkup.Regexes.omittedElements, with: "")
    guard let document = try? XMLDocument(xmlString: cleaned, options: .documentTidyHTML),
      let root = document.rootElement()
    else { return nil }
    let text = markdown(root, baseURL: baseURL)
      .replacingOccurrences(of: #"\n[ \t]+\n"#, with: "\n\n", options: .regularExpression)
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  private static func markdown(_ node: XMLNode, baseURL: URL?, listDepth: Int = 0) -> String {
    guard let element = node as? XMLElement else {
      guard node.kind == .text else { return "" }
      var text = (node.stringValue ?? "").replacingOccurrences(
        of: #"\s+"#, with: " ", options: .regularExpression)
      for character in ["\\", "*", "_", "[", "]", "`"] {
        text = text.replacingOccurrences(of: character, with: "\\" + character)
      }
      return text.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(
        of: ">", with: "&gt;")
    }
    let tag = element.localName?.lowercased() ?? ""
    if [
      "head", "script", "style", "nav", "footer", "aside", "form", "button", "svg", "img", "video",
      "iframe", "noscript",
    ].contains(tag) {
      return ""
    }
    let classes = element.attribute(forName: "class")?.stringValue ?? ""
    if classes.split(separator: " ").contains(where: {
      ["visionos", "ios", "windows", "android"].contains(String($0))
    }) && ["article", "section"].contains(tag) {
      return ""
    }
    if element.attribute(forName: "aria-hidden")?.stringValue == "true" { return "" }
    let children = element.children ?? []
    if tag == "pre" { return "\n\n```\n\(element.stringValue ?? "")\n```\n\n" }
    if tag == "ul" || tag == "ol" {
      var ordinal = Int(element.attribute(forName: "start")?.stringValue ?? "1") ?? 1
      var result = "\n"
      for child in children where child.name == "li" {
        let body = (child.children ?? []).map {
          markdown($0, baseURL: baseURL, listDepth: listDepth + 1)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = tag == "ol" ? "\(ordinal). " : "- "
        let indentation = String(repeating: "    ", count: listDepth)
        let lines = body.components(separatedBy: .newlines)
        result += indentation + marker + (lines.first ?? "") + "\n"
        for line in lines.dropFirst() {
          result += line.hasPrefix("    ") ? line + "\n" : indentation + "    " + line + "\n"
        }
        ordinal += 1
      }
      return result + (listDepth == 0 ? "\n" : "")
    }
    if tag.count == 2, tag.first == "h", let level = Int(tag.suffix(1)), (1...6).contains(level) {
      // Heading spans can be visually separated version badges without source whitespace.
      let heading = children.map { child in
        let text = markdown(child, baseURL: baseURL, listDepth: listDepth)
        return child.name?.lowercased() == "span" ? " " + text + " " : text
      }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
      return "\n\n" + String(repeating: "#", count: level) + " "
        + heading.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) + "\n\n"
    }
    let body = children.map { markdown($0, baseURL: baseURL, listDepth: listDepth) }.joined()
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    switch tag {
    case "br": return "  \n"
    case "p": return listDepth > 0 ? trimmed + "\n" : "\n\n" + trimmed + "\n\n"
    case "div", "section", "article", "main", "header", "tr", "dl": return "\n\n" + trimmed + "\n\n"
    case "td", "th", "dt", "dd": return trimmed + "\n"
    // Blogger wraps line breaks in otherwise empty formatting elements.
    // Preserve those breaks instead of emitting empty Markdown delimiters.
    case "strong", "b": return trimmed.isEmpty ? body : "**" + trimmed + "**"
    case "em", "i": return trimmed.isEmpty ? body : "*" + trimmed + "*"
    case "code": return "`" + (element.stringValue ?? "") + "`"
    case "span": return body
    case "a":
      guard !trimmed.isEmpty, let href = element.attribute(forName: "href")?.stringValue,
        let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
      else { return body }
      return "[" + trimmed + "](" + url.absoluteString.replacingOccurrences(of: " ", with: "%20")
        + ")"
    case "hr": return "\n\n"
    default: return body
    }
  }

  /// Let Foundation identify actual Markdown code blocks/spans, including
  /// delimiter lengths and paragraph boundaries, before rewriting mixed HTML.
  private static func protectCodeHTML(_ source: String, marker: String) -> String {
    guard source.contains("<") else { return source }
    // These wrappers are removed below. Neutralize their HTML-block behavior
    // for code detection, retaining every source offset (including inside code).
    let detectionSource = NSMutableString(string: source)
    for match in ReleaseNotesMarkup.Regexes.markdownDisclosureTag.matches(
      in: source, range: NSRange(location: 0, length: detectionSource.length))
    {
      detectionSource.replaceCharacters(
        in: NSRange(location: match.range.location, length: 1), with: "x")
    }
    guard
      let parsed = try? AttributedString(
        markdown: detectionSource as String,
        options: .init(interpretedSyntax: .full, appliesSourcePositionAttributes: true))
    else { return source }
    // Markdown positions use one-based UTF-8 columns. Index line starts once,
    // avoiding repeated String/UTF-16 traversal for documents with many spans.
    let input = Array(source.utf8)
    let markerBytes = Array(marker.utf8)
    var lineStarts = [0]
    for index in input.indices
    where input[index] == 10
      || (input[index] == 13 && (index + 1 == input.count || input[index + 1] != 10))
    { lineStarts.append(index + 1) }
    var result = [UInt8]()
    result.reserveCapacity(input.count)
    var cursor = 0
    for run in parsed.runs {
      let code =
        run.inlinePresentationIntent?.contains(.code) == true
        || run.presentationIntent?.components.contains {
          if case .codeBlock = $0.kind { return true }
          return false
        } == true
      guard code, let position = run.markdownSourcePosition else { continue }
      guard lineStarts.indices.contains(position.startLine - 1),
        lineStarts.indices.contains(position.endLine - 1),
        position.startColumn > 0, position.endColumn > 0
      else { continue }
      let start = lineStarts[position.startLine - 1] + position.startColumn - 1
      let end = lineStarts[position.endLine - 1] + position.endColumn
      guard start >= cursor, end >= start, end <= input.count else { continue }
      result.append(contentsOf: input[cursor..<start])
      for byte in input[start..<end] {
        if byte == 60 { result.append(contentsOf: markerBytes) } else { result.append(byte) }
      }
      cursor = end
    }
    guard cursor > 0 else { return source }
    result.append(contentsOf: input[cursor...])
    return String(decoding: result, as: UTF8.self)
  }

  static func prepare(_ markdown: String, baseURL: URL? = nil) -> AttributedString {
    var codeMarker = "LATEST-CODE-" + UUID().uuidString
    while markdown.contains(codeMarker) { codeMarker += "-" }
    let protected = protectCodeHTML(markdown, marker: codeMarker)
    var inComment = false
    var source = protected.components(separatedBy: .newlines).compactMap { line -> String? in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if inComment || trimmed.hasPrefix("<!--") {
        inComment = !trimmed.contains("-->")
        return nil
      }
      // Code literals are shielded, so only real HTML wrappers are removed.
      if trimmed.range(
        of: #"(?i)^<a\b[^>]*>\s*<img\b[^>]*>\s*</a>$"#, options: .regularExpression) != nil
      {
        return nil
      }
      if trimmed.range(of: #"^</?details\b[^>]*>$"#, options: .regularExpression) != nil {
        return nil
      }
      return line.replacingOccurrences(
        of: #"^\s*<summary>(.*?)</summary>\s*$"#, with: "**$1**", options: .regularExpression)
    }.joined(separator: "\n")
    for (tag, marker) in [("code", "`"), ("strong", "**"), ("b", "**"), ("em", "*"), ("i", "*")] {
      source = source.replacingOccurrences(
        of: "(?is)<" + tag + "\\b[^>]*>(.*?)</" + tag + ">", with: marker + "$1" + marker,
        options: .regularExpression)
    }
    source = source.replacingOccurrences(of: codeMarker, with: "<")
    guard
      let parsed = try? AttributedString(
        markdown: source, options: .init(interpretedSyntax: .full), baseURL: baseURL)
    else {
      var text = AttributedString(markdown)
      text[ReleaseNotesStyleKey.self] = ReleaseNotesStyle()
      text.font = .system(size: 13)
      return text
    }
    var result = AttributedString()
    var previousBlock: Int?
    var emittedListItems = Set<Int>()
    for run in parsed.runs {
      let components = run.presentationIntent?.components ?? []
      let block = components.first?.identity
      let newBlock = block != previousBlock || result.characters.isEmpty
      let heading = components.contains {
        if case .header = $0.kind { return true }
        return false
      }
      let code = components.contains {
        if case .codeBlock = $0.kind { return true }
        return false
      }
      let lists = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }
      let inline = run.inlinePresentationIntent ?? []
      var style = ReleaseNotesStyle(
        bold: heading || inline.contains(.stronglyEmphasized),
        italic: inline.contains(.emphasized),
        monospaced: code || inline.contains(.code),
        strikethrough: inline.contains(.strikethrough),
        paragraph: .init(
          spacing: lists.isEmpty ? 8 : 4,
          spacingBefore: heading && !result.characters.isEmpty ? 5 : 0,
          headIndent: lists.isEmpty ? 0 : Double(lists.count - 1) * 16 + 14,
          firstLineHeadIndent: lists.isEmpty ? 0 : Double(lists.count - 1) * 16))
      var attributes = AttributeContainer()
      attributes[ReleaseNotesStyleKey.self] = style
      var font = Font.system(
        size: style.monospaced ? 12 : 13, design: style.monospaced ? .monospaced : .default)
      if style.bold { font = font.bold() }
      if style.italic { font = font.italic() }
      attributes.font = font
      attributes.foregroundColor = .primary
      if let link = run.link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "")
      {
        attributes.link = link.absoluteURL
      }
      if newBlock {
        if !result.characters.isEmpty { result.append(AttributedString("\n")) }
        if let list = lists.first,
          let item = components.first(where: {
            if case .listItem = $0.kind { return true }
            return false
          }), case .listItem(let ordinal) = item.kind
        {
          if emittedListItems.insert(item.identity).inserted {
            result.append(
              AttributedString(
                list.kind == .orderedList ? "\(ordinal). " : "• ", attributes: attributes))
          } else {
            if var paragraph = style.paragraph {
              paragraph.firstLineHeadIndent = paragraph.headIndent
              style.paragraph = paragraph
            }
            attributes[ReleaseNotesStyleKey.self] = style
          }
        }
      }
      result.append(
        AttributedString(String(parsed[run.range].characters), attributes: attributes))
      previousBlock = block
    }
    if !result.characters.isEmpty { result.append(AttributedString("\n")) }
    return result
  }
}

/// Semantic formatting survives preparation without constructing AppKit text objects.
struct ReleaseNotesStyle: Codable, Hashable, Sendable {
  struct Paragraph: Codable, Hashable, Sendable {
    let spacing: Double
    let spacingBefore: Double
    let headIndent: Double
    var firstLineHeadIndent: Double
  }
  var bold = false
  var italic = false
  var monospaced = false
  var strikethrough = false
  var paragraph: Paragraph?
}

struct ReleaseNotesStyleKey: AttributedStringKey {
  typealias Value = ReleaseNotesStyle
  static let name = "Latest.ReleaseNotesStyle"
}

/// Immutable semantic content shared by preparation, caching and WebKit.
/// Reference identity preserves the page's existing reload/scroll-reset contract.
final class ReleaseNotesContent: Codable, Sendable {
  struct Run: Codable, Hashable, Sendable {
    var text: String
    let style: ReleaseNotesStyle?
    let link: URL?

    init(text: String, style: ReleaseNotesStyle? = nil, link: URL? = nil) {
      self.text = text
      self.style = style
      self.link = link
    }
  }

  let runs: [Run]
  let string: String
  let length: Int

  init(runs: [Run]) {
    self.runs = runs
    string = runs.map(\.text).joined()
    length = string.utf16.count
  }

  convenience init(string: String) {
    self.init(runs: [Run(text: string)])
  }

  convenience init(_ text: AttributedString) {
    var runs: [Run] = []
    for run in text.runs {
      let next = Run(
        text: String(text[run.range].characters),
        style: run[ReleaseNotesStyleKey.self], link: run.link)
      // The former NSMutableAttributedString merged adjacent equal attributes.
      // Keep that segmentation so generated HTML stays byte-identical.
      if let previous = runs.last, previous.style == next.style, previous.link == next.link {
        runs[runs.count - 1].text += next.text
      } else {
        runs.append(next)
      }
    }
    self.init(runs: runs)
  }

  private enum CodingKeys: String, CodingKey { case runs }

  convenience init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(runs: container.decode([Run].self, forKey: .runs))
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(runs, forKey: .runs)
  }
}
