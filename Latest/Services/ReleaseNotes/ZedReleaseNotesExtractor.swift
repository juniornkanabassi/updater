//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-09-05.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation

enum ZedReleaseNotesExtractor {
  static func zedReleaseText(fromHTML html: String, version: String?, pageURL: URL) -> String? {
    guard pageURL.host?.localizedCaseInsensitiveContains("zed.dev") == true,
      let version = version?.trimmingCharacters(in: .whitespacesAndNewlines),
      !version.isEmpty
    else {
      return nil
    }

    // Zed's version page currently contains both rendered article text and React
    // transport records. Prefer the rendered article: transport descriptions can
    // be references or partial payloads even when they decode successfully.
    if let articleHTML = Self.zedArticleBodyHTML(fromHTML: html, version: version),
      let text = ReleaseNotesMarkup.plainText(fromHTML: articleHTML),
      let cleanedText = Self.cleanedZedReleaseText(text),
      Self.isUsefulZedReleaseArticleText(cleanedText)
    {
      return cleanedText
    }

    if let text = ReleaseNotesMarkup.plainText(fromHTML: html),
      let releaseText = Self.zedReleaseText(fromPlainText: text, version: version),
      let cleanedText = Self.cleanedZedReleaseText(releaseText),
      ReleaseNotesMarkup.isUsefulReleaseNotesText(cleanedText, relevantVersion: version)
    {
      return cleanedText
    }

    let escapedVersion = NSRegularExpression.escapedPattern(for: version)
    let pattern =
      #"\\\"release\\\":\{\\\"version\\\":\\\""# + escapedVersion
      + #"\\\",\\\"description\\\":\\\"((?:\\\\.|[^\\\"])*)\\\""#
    if let regex = try? NSRegularExpression(pattern: pattern) {
      let htmlRange = NSRange(html.startIndex..<html.endIndex, in: html)
      if let match = regex.firstMatch(in: html, range: htmlRange),
        let descriptionRange = Range(match.range(at: 1), in: html)
      {
        let escapedDescription = String(html[descriptionRange])
        let jsonString = "\"\(escapedDescription)\""
        if let data = jsonString.data(using: .utf8),
          let decodedDescription = try? JSONDecoder().decode(String.self, from: data)
        {
          let description =
            decodedDescription
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

          if ReleaseNotesMarkup.isReactServerReference(description),
            let referencedDescription = ReleaseNotesMarkup.reactServerText(
              for: description, in: html),
            let cleanedText = Self.cleanedZedReleaseText(referencedDescription),
            ReleaseNotesMarkup.isUsefulReleaseNotesText(cleanedText, relevantVersion: version)
          {
            return cleanedText
          }

          if !description.isEmpty, !ReleaseNotesMarkup.isReactServerReference(description) {
            return description
          }
        }
      }
    }

    return nil
  }

  private static func zedReleaseText(fromPlainText text: String, version: String) -> String? {
    let lines = text.components(separatedBy: .newlines).compactMap { line -> String? in
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedLine.isEmpty ? nil : trimmedLine
    }
    guard !lines.isEmpty else { return nil }

    let candidates = ReleaseNotesMarkup.versionCandidates(from: version)
    guard
      let startIndex = lines.indices.first(where: { index in
        guard ReleaseNotesMarkup.isBareVersionLine(lines[index]),
          ReleaseNotesMarkup.lineContainsVersionCandidate(lines[index], candidates: candidates),
          lines.indices.contains(index + 1)
        else {
          return false
        }

        return ReleaseNotesMarkup.looksLikeDateReleaseBoundary(lines[index + 1])
      })
    else {
      return nil
    }

    var endIndex = lines.endIndex
    for index in (startIndex + 1)..<lines.endIndex {
      if index != startIndex,
        ReleaseNotesMarkup.looksLikeVersionBoundary(lines[index]),
        !ReleaseNotesMarkup.lineContainsVersionCandidate(lines[index], candidates: candidates)
      {
        endIndex = index
        break
      }
    }

    return lines[startIndex..<endIndex].joined(separator: "\n")
  }

  private static func cleanedZedReleaseText(_ text: String) -> String? {
    let lines = text.components(separatedBy: .newlines).compactMap { line -> String? in
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedLine.isEmpty,
        !["-", "–", "—"].contains(trimmedLine),
        !ReleaseNotesMarkup.zedReleaseChromeLines.contains(trimmedLine.lowercased())
      else {
        return nil
      }

      return trimmedLine
    }

    let cleanedText = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return cleanedText.isEmpty ? nil : cleanedText
  }

  private static func zedArticleBodyHTML(fromHTML html: String, version: String) -> String? {
    let identifiers = ["id=\"zed-\(version)\"", "id='zed-\(version)'"]
    guard
      let cardIdentifier = identifiers.compactMap({ identifier in
        html.range(of: identifier, options: [.caseInsensitive, .diacriticInsensitive])
      }).min(by: { $0.lowerBound < $1.lowerBound }),
      let articleTag = html.range(
        of: "<article",
        options: [.caseInsensitive, .diacriticInsensitive],
        range: cardIdentifier.upperBound..<html.endIndex
      ),
      let articleBodyStart = html.range(of: ">", range: articleTag.upperBound..<html.endIndex)?
        .upperBound,
      let articleBodyEnd = html.range(
        of: "</article>",
        options: [.caseInsensitive, .diacriticInsensitive],
        range: articleBodyStart..<html.endIndex
      )?.lowerBound
    else {
      return nil
    }
    return String(html[articleBodyStart..<articleBodyEnd])
  }

  static func isUsefulZedReleaseArticleText(_ text: String) -> Bool {
    guard text.count >= 80,
      !ReleaseNotesMarkup.looksLikeBinaryOrMojibakeText(text)
    else {
      return false
    }
    return text.range(
      of: #"(?m)^(This week's release|Features|Bug Fixes|Shipped by the Zed Guild)\b"#,
      options: [.regularExpression, .caseInsensitive]
    ) != nil
  }
}
