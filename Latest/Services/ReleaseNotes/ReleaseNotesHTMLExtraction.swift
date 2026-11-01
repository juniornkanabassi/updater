//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-09-05.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation

extension ReleaseNotesMarkup {
  static func releaseContentHTML(fromHTML html: String, version: String?, pageURL: URL) -> String? {
    let isObsidianChangelog = pageURL.host?.localizedCaseInsensitiveContains("obsidian.md") == true
    if isObsidianChangelog,
      let article = Self.versionedReleaseArticleHTML(
        fromHTML: html, version: version, preferredSuffix: "Desktop"),
      Self.isUsefulReleaseNotesText(article, relevantVersion: version)
    {
      return article
    }

    if let article = Self.versionedReleaseArticleHTML(fromHTML: html, version: version),
      Self.isUsefulReleaseNotesText(article, relevantVersion: version)
    {
      return article
    }

    if isObsidianChangelog,
      !Self.isObsidianChangelogIndex(pageURL),
      let content = Self.firstHTMLBlock(in: html, tagName: "div", marker: #"class="typeset"#),
      Self.isUsefulReleaseNotesText(content, relevantVersion: version)
    {
      return content
    }

    return nil
  }

  static func plainText(fromHTML html: String) -> String? {
    var text = html

    text = replacingMatches(in: text, matching: Regexes.omittedElements, with: "\n")
    text = replacingMatches(in: text, matching: Regexes.lineBreak, with: "\n")
    text = replacingMatches(in: text, matching: Regexes.listItem, with: "\n- ")
    text = replacingMatches(in: text, matching: Regexes.blockOpening, with: "\n")
    text = replacingMatches(in: text, matching: Regexes.blockClosing, with: "\n")
    text = replacingMatches(in: text, matching: Regexes.anyTag, with: " ")
    text = Self.decodingHTMLEntities(in: text)
    text = text.replacingOccurrences(of: "\u{00a0}", with: " ")

    let lines = text.components(separatedBy: .newlines).compactMap { line -> String? in
      let trimmedLine = replacingMatches(
        in: line.trimmingCharacters(in: .whitespacesAndNewlines),
        matching: Regexes.repeatedWhitespace,
        with: " "
      )
      return trimmedLine.isEmpty ? nil : trimmedLine
    }

    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }

  static func firstReleaseNotesURL(in markup: String, baseURL: URL?) -> URL? {
    if let hrefURL = Self.firstHrefURL(in: markup, baseURL: baseURL) {
      return hrefURL
    }

    let range = NSRange(markup.startIndex..<markup.endIndex, in: markup)
    for match in Regexes.firstRawURL.matches(in: markup, range: range) {
      guard let matchRange = Range(match.range, in: markup) else { continue }
      let urlString = String(markup[matchRange]).trimmingCharacters(
        in: CharacterSet(charactersIn: ".,;)"))
      if let url = URL(string: urlString), isReleaseNotesLink(url) { return url }
    }
    return nil
  }

  static func linkedChangelogURL(fromHTML html: String, version: String?, pageURL: URL) -> URL? {
    let candidates = versionCandidates(from: version)
    guard !candidates.isEmpty else { return nil }

    let range = NSRange(html.startIndex..<html.endIndex, in: html)
    let matches = Regexes.anchorWithLabel.matches(in: html, range: range)
    var fallbackURL: URL?
    var preferredURL: URL?

    for match in matches {
      guard let hrefRange = Range(match.range(at: 1), in: html),
        let labelRange = Range(match.range(at: 2), in: html)
      else {
        continue
      }

      let href = Self.decodingHTMLEntities(in: String(html[hrefRange]))
      let labelHTML = String(html[labelRange])
      let label = Self.plainText(fromHTML: labelHTML) ?? labelHTML
      let searchText = href + "\n" + label
      guard
        Self.lineContainsVersionCandidate(searchText, candidates: candidates)
      else {
        continue
      }

      guard let url = URL(string: href, relativeTo: pageURL)?.absoluteURL, isReleaseNotesLink(url)
      else {
        continue
      }

      if fallbackURL == nil {
        fallbackURL = url
      }

      if searchText.range(of: "desktop", options: [.caseInsensitive, .diacriticInsensitive]) != nil
      {
        preferredURL = url
        break
      }
    }

    return preferredURL ?? fallbackURL
  }

  static func isReleaseNotesLink(_ url: URL) -> Bool {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
    let path = url.path.lowercased()
    guard !path.contains("/pull/"), !path.contains("/issues/"), !path.contains("/compare/"),
      !ReleaseNotesProviderConstants.downloadExtensions.contains(url.pathExtension.lowercased())
    else { return false }
    return path.range(
      of: #"(release|changelog|change-log|notes|whatsnew|what-s-new|updates)"#,
      options: .regularExpression) != nil
  }

  static func isReactServerReference(_ text: String) -> Bool {
    text.range(of: #"^\$[0-9A-Za-z]+$"#, options: .regularExpression) != nil
  }

  private static func isObsidianChangelogIndex(_ url: URL) -> Bool {
    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return path == "changelog"
  }

  private static func versionedReleaseArticleHTML(
    fromHTML html: String, version: String?, preferredSuffix: String? = nil
  ) -> String? {
    let candidates = Self.versionCandidates(from: version)
    guard !candidates.isEmpty else { return nil }

    var searchStart = html.startIndex
    var fallbackArticleHTML: String?
    while let article = Self.nextHTMLElement(in: html, tagName: "article", searchStart: searchStart)
    {
      let articleHTML = String(html[article.range])
      let articleText = Self.plainText(fromHTML: articleHTML) ?? articleHTML
      let openingTag = String(articleHTML.prefix(200)).lowercased()
      if openingTag.range(
        of: #"class=["'][^"']*\b(visionos|ios|windows|android)\b"#, options: .regularExpression)
        != nil
      {
        searchStart = article.range.upperBound
        continue
      }
      let heading =
        articleHTML.range(of: #"(?is)<h[1-6]\b[^>]*>.*?</h[1-6]>"#, options: .regularExpression)
        .flatMap { Self.plainText(fromHTML: String(articleHTML[$0])) }
        ?? String(articleText.prefix(200))
      if Self.lineContainsVersionCandidate(heading, candidates: candidates) {
        if let preferredSuffix {
          if candidates.contains(where: { candidate in
            articleText.range(
              of: "\(candidate) \(preferredSuffix)",
              options: [.caseInsensitive, .diacriticInsensitive]) != nil
          }) {
            return articleHTML
          }
          if fallbackArticleHTML == nil {
            fallbackArticleHTML = articleHTML
          }
          searchStart = article.range.upperBound
          continue
        }

        return articleHTML
      }

      searchStart = article.range.upperBound
    }

    return preferredSuffix == nil ? fallbackArticleHTML : nil
  }

  private static func firstHTMLBlock(in html: String, tagName: String, marker: String) -> String? {
    guard let markerRange = html.range(of: marker, options: .regularExpression),
      let openingRange = html[..<markerRange.lowerBound].range(
        of: "<\(tagName)", options: [.backwards, .caseInsensitive])
    else {
      return nil
    }

    return Self.nextHTMLElement(in: html, tagName: tagName, searchStart: openingRange.lowerBound)
      .map { element in
        String(html[element.range])
      }
  }

  static func nextHTMLElement(in html: String, tagName: String, searchStart: String.Index) -> (
    range: Range<String.Index>, contentRange: Range<String.Index>
  )? {
    let escapedTagName = NSRegularExpression.escapedPattern(for: tagName)
    guard
      let regex = try? NSRegularExpression(
        pattern: "(?is)</?\(escapedTagName)\\b[^>]*>"
      )
    else {
      return nil
    }
    let searchRange = NSRange(searchStart..<html.endIndex, in: html)
    var openingRange: Range<String.Index>?
    var element: (range: Range<String.Index>, contentRange: Range<String.Index>)?
    var depth = 0
    // Stop at this element's closing tag. Collecting every later match makes
    // walking a changelog repeatedly scan and allocate its remaining tail.
    regex.enumerateMatches(in: html, range: searchRange) { match, _, stop in
      guard let match, let tokenRange = Range(match.range, in: html) else { return }
      let token = html[tokenRange]
      let isClosing = token.hasPrefix("</")
      let isSelfClosing = token.dropLast().last == "/"
      if openingRange == nil {
        guard !isClosing else {
          stop.pointee = true
          return
        }
        openingRange = tokenRange
      }
      if isClosing {
        depth -= 1
        if depth == 0, let openingRange {
          element = (
            range: openingRange.lowerBound..<tokenRange.upperBound,
            contentRange: openingRange.upperBound..<tokenRange.lowerBound
          )
          stop.pointee = true
        }
      } else if !isSelfClosing {
        depth += 1
      }
    }

    return element
  }

  static func reactServerText(for reference: String, in html: String) -> String? {
    let identifier = String(reference.dropFirst())
    guard !identifier.isEmpty else { return nil }

    let markerPattern = NSRegularExpression.escapedPattern(for: identifier) + #":T[0-9A-Fa-f]+,"#
    guard let markerRange = html.range(of: markerPattern, options: .regularExpression) else {
      return nil
    }

    let remainingHTML = String(html[markerRange.upperBound...])
    let textPattern = #"(?s)self\.__next_f\.push\(\[1,"((?:\\.|[^"\\])*)"\]\)</script>"#
    guard let regex = try? NSRegularExpression(pattern: textPattern),
      let match = regex.firstMatch(
        in: remainingHTML,
        range: NSRange(remainingHTML.startIndex..<remainingHTML.endIndex, in: remainingHTML)),
      let textRange = Range(match.range(at: 1), in: remainingHTML)
    else {
      return nil
    }

    let escapedText = String(remainingHTML[textRange])
    let jsonString = "\"\(escapedText)\""
    guard let data = jsonString.data(using: .utf8),
      let decodedText = try? JSONDecoder().decode(String.self, from: data)
    else {
      return nil
    }

    return decodedText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func firstHrefURL(in html: String, baseURL: URL?) -> URL? {
    let range = NSRange(html.startIndex..<html.endIndex, in: html)
    for match in Regexes.anchorHref.matches(in: html, range: range) {
      guard let hrefRange = Range(match.range(at: 1), in: html) else { continue }
      let href = Self.decodingHTMLEntities(in: String(html[hrefRange]))
      if let url = URL(string: href, relativeTo: baseURL)?.absoluteURL, isReleaseNotesLink(url) {
        return url
      }
    }
    return nil
  }

  static func decodingHTMLEntities(in string: String) -> String {
    let replacements = [
      "&nbsp;": " ",
      "&amp;": "&",
      "&lt;": "<",
      "&gt;": ">",
      "&quot;": "\"",
      "&#39;": "'",
      "&apos;": "'",
      "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”",
      "&mdash;": "—", "&ndash;": "–", "&middot;": "·", "&copy;": "©",
      "&hellip;": "…", "&bull;": "•", "&reg;": "®",
    ]

    guard string.contains("&") else { return string }
    let input = string as NSString
    var result = ""
    result.reserveCapacity(string.utf8.count)
    var cursor = 0
    Regexes.htmlEntity.enumerateMatches(
      in: string, range: NSRange(location: 0, length: input.length)
    ) { match, _, _ in
      guard let match else { return }
      let entity = input.substring(with: match.range)
      let replacement: String?
      if let named = replacements[entity] {
        replacement = named
      } else if entity.hasPrefix("&#") {
        let number = entity.dropFirst(2).dropLast()
        let hexadecimal = number.first == "x" || number.first == "X"
        let value = UInt32(hexadecimal ? number.dropFirst() : number, radix: hexadecimal ? 16 : 10)
        replacement = value.flatMap(UnicodeScalar.init).map(String.init)
      } else {
        replacement = nil
      }
      guard let replacement else { return }
      // Read only original UTF-16 ranges. Decoded output must never be decoded
      // again, and mutating suffixes per entity makes dense inputs quadratic.
      result += input.substring(
        with: NSRange(location: cursor, length: match.range.location - cursor))
      result += replacement
      cursor = NSMaxRange(match.range)
    }
    guard cursor > 0 else { return string }
    result += input.substring(from: cursor)
    return result
  }
}
