//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-09-05.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation

enum ChromeReleaseNotesExtractor {
  static func chromeDesktopReleaseText(fromHTML html: String, version: String?, pageURL: URL)
    -> String?
  {
    guard pageURL.host?.localizedCaseInsensitiveContains("chromereleases.googleblog.com") == true
    else {
      return nil
    }

    let candidates = ReleaseNotesMarkup.versionCandidates(from: version).filter {
      $0.split(separator: ".", omittingEmptySubsequences: false).count >= 4
    }
    if let releaseText = Self.chromeDesktopReleaseTextFromBloggerTemplate(
      html, version: version, candidates: candidates, pageURL: pageURL)
    {
      return releaseText
    }

    guard let text = ReleaseNotesMarkup.plainText(fromHTML: html) else { return nil }
    return Self.chromeDesktopReleaseText(
      fromPlainText: text, version: version, candidates: candidates)
  }

  private static func chromeDesktopReleaseTextFromBloggerTemplate(
    _ html: String, version: String?, candidates: [String], pageURL: URL
  ) -> String? {
    var searchStart = html.startIndex
    while let titleRange = html.range(
      of: "Stable Channel Update for Desktop", options: [.caseInsensitive, .diacriticInsensitive],
      range: searchStart..<html.endIndex)
    {
      let postStart =
        html[..<titleRange.lowerBound].range(
          of: "<div class='post'", options: [.backwards, .caseInsensitive])?.lowerBound
        ?? titleRange.lowerBound
      let postEnd =
        html.range(
          of: "<div class='post'", options: [.caseInsensitive],
          range: titleRange.upperBound..<html.endIndex)?.lowerBound ?? html.endIndex
      let postHTML = String(html[postStart..<postEnd])

      if let bodyMarkup = Self.chromeBloggerBodyMarkup(in: postHTML),
        let bodyText = ReleaseNotesMarkup.plainText(fromHTML: bodyMarkup)
      {
        let releaseText = "Stable Channel Update for Desktop\n" + bodyText
        if Self.chromeReleaseTextMatches(releaseText, version: version, candidates: candidates),
          ReleaseNotesMarkup.isUsefulReleaseNotesText(releaseText, relevantVersion: nil)
        {
          if let markdown = ReleaseNotesDocument.markdown(fromHTML: bodyMarkup, baseURL: pageURL) {
            return "## Stable Channel Update for Desktop\n\n" + markdown
          }
          return releaseText.components(separatedBy: .newlines).joined(separator: "\n\n")
        }
      }

      searchStart = titleRange.upperBound
    }

    return nil
  }

  private static func chromeBloggerBodyMarkup(in html: String) -> String? {
    var searchStart = html.startIndex
    while let element = ReleaseNotesMarkup.nextHTMLElement(
      in: html, tagName: "script", searchStart: searchStart)
    {
      let openingTag = String(html[element.range.lowerBound..<element.contentRange.lowerBound])
      if openingTag.range(
        of: #"type\s*=\s*['"]text/template['"]"#, options: [.regularExpression, .caseInsensitive])
        != nil
      {
        return String(html[element.contentRange])
      }

      searchStart = element.range.upperBound
    }

    if let element = ReleaseNotesMarkup.nextHTMLElement(
      in: html, tagName: "noscript", searchStart: html.startIndex)
    {
      return String(html[element.contentRange])
    }

    return nil
  }

  private static func chromeDesktopReleaseText(
    fromPlainText text: String, version: String?, candidates: [String]
  ) -> String? {
    let lines = text.components(separatedBy: .newlines).compactMap { line -> String? in
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedLine.isEmpty ? nil : trimmedLine
    }
    guard !lines.isEmpty, !candidates.isEmpty else { return nil }

    guard
      let versionLineIndex = lines.firstIndex(where: { line in
        Self.chromeReleaseLineMatches(line, version: version, candidates: candidates)
      })
    else {
      return nil
    }

    let startIndex =
      lines[..<versionLineIndex].indices.reversed().first { index in
        let line = lines[index]
        return line.localizedCaseInsensitiveContains("Desktop")
          && line.localizedCaseInsensitiveContains("Update")
      } ?? versionLineIndex

    var endIndex = lines.endIndex
    if versionLineIndex + 1 < lines.endIndex {
      for index in (versionLineIndex + 1)..<lines.endIndex {
        let line = lines[index]
        if index > startIndex,
          line.localizedCaseInsensitiveContains("Update"),
          Self.looksLikeChromeReleaseHeading(line),
          !Self.lineMatchesChromeVersion(line, version: version, candidates: candidates)
        {
          endIndex = index
          break
        }
      }
    }

    let releaseText = lines[startIndex..<endIndex].joined(separator: "\n\n")
    guard ReleaseNotesMarkup.isUsefulReleaseNotesText(releaseText, relevantVersion: nil) else {
      return nil
    }

    return releaseText
  }

  private static func chromeReleaseTextMatches(
    _ text: String, version: String?, candidates: [String]
  ) -> Bool {
    text.components(separatedBy: .newlines).contains { line in
      Self.chromeReleaseLineMatches(line, version: version, candidates: candidates)
    }
  }

  private static func chromeReleaseLineMatches(
    _ line: String, version: String?, candidates: [String]
  ) -> Bool {
    let lowercased = line.lowercased()
    return lowercased.contains("windows") && lowercased.contains("mac")
      && !lowercased.contains("android releases contain")
      && Self.lineMatchesChromeVersion(line, version: version, candidates: candidates)
  }

  private static func lineMatchesChromeVersion(
    _ line: String, version: String?, candidates: [String]
  ) -> Bool {
    if candidates.contains(where: { candidate in
      line.range(of: candidate, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }) {
      return true
    }

    guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty
    else {
      return false
    }

    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 4 else { return false }

    let prefix = parts.dropLast().joined(separator: ".")
    let suffix = String(parts.last ?? "")
    guard !prefix.isEmpty, !suffix.isEmpty else { return false }

    let escapedPrefix = NSRegularExpression.escapedPattern(for: prefix)
    let escapedSuffix = NSRegularExpression.escapedPattern(for: suffix)
    return line.range(
      of: #"\b\#(escapedPrefix)\.\d+/\.?\#(escapedSuffix)\b"#,
      options: [.regularExpression, .caseInsensitive]
    ) != nil
  }

  private static func looksLikeChromeReleaseHeading(_ line: String) -> Bool {
    let lowercased = line.lowercased()
    return lowercased.contains("desktop") || lowercased.contains("chromeos")
      || lowercased.hasPrefix("chrome for ") || lowercased.hasPrefix("beta channel")
      || lowercased.hasPrefix("dev channel")
  }
}
