//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-09-05.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation

enum ZoomReleaseNotesExtractor {
  static func zoomReleaseText(fromHTML html: String, version: String?, pageURL: URL) -> String? {
    guard pageURL.host?.localizedCaseInsensitiveContains("zoom.com") == true,
      let text = ReleaseNotesMarkup.plainText(
        fromHTML: Self.zoomTableAwareHTML(Self.zoomArticleBodyHTML(fromHTML: html) ?? html))
    else {
      return nil
    }

    let normalizedText =
      text
      .replacingOccurrences(of: #"\\r\\n|\\n|\\r"#, with: "\n", options: .regularExpression)

    let lines = normalizedText.components(separatedBy: .newlines).compactMap { line -> String? in
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedLine.isEmpty ? nil : trimmedLine
    }
    guard !lines.isEmpty else { return nil }

    // The bundle includes the build in parentheses, while section headings do not.
    let releaseVersion = version?.replacingOccurrences(
      of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
    let candidates = ReleaseNotesMarkup.versionCandidates(from: releaseVersion)
    guard !candidates.isEmpty else { return nil }

    let versionIndexes = lines.indices.filter { index in
      let line = lines[index]
      return
        (ReleaseNotesMarkup.looksLikeDateReleaseBoundary(line)
        || line.range(of: #"^\d+(?:\.\d+)+\s*(?:\(|$)"#, options: .regularExpression) != nil)
        && ReleaseNotesMarkup.lineContainsVersionCandidate(line, candidates: candidates)
    }

    for versionIndex in versionIndexes {
      let startIndex =
        ReleaseNotesMarkup.looksLikeDateReleaseBoundary(lines[versionIndex])
        ? versionIndex
        : lines[..<versionIndex].indices.reversed().first { index in
          ReleaseNotesMarkup.looksLikeDateReleaseBoundary(lines[index])
        } ?? versionIndex

      var endIndex = lines.endIndex
      for index in (startIndex + 1)..<lines.endIndex {
        if ReleaseNotesMarkup.looksLikeDateReleaseBoundary(lines[index]) {
          endIndex = index
          break
        }
      }

      var selectedLines = Array(lines[startIndex..<endIndex])
      // Zoom can publish two patch trains on the same date. Choose the matching table.
      if let fullVersionIndex = selectedLines.firstIndex(where: {
        $0.hasPrefix("Full versions for ")
          && ReleaseNotesMarkup.lineContainsVersionCandidate($0, candidates: candidates)
      }) {
        let nextVersion =
          selectedLines.indices.dropFirst(fullVersionIndex + 1).first {
            selectedLines[$0].hasPrefix("Full versions for ")
          } ?? selectedLines.endIndex
        selectedLines = [lines[startIndex]] + Array(selectedLines[fullVersionIndex..<nextVersion])
      }
      let cleanedText = Self.cleanedZoomReleaseText(selectedLines)
      guard Self.looksLikeZoomReleaseBody(cleanedText),
        ReleaseNotesMarkup.isUsefulReleaseNotesText(cleanedText, relevantVersion: version)
      else {
        continue
      }

      return Self.zoomReleaseTextWithVersionHeader(cleanedText, version: version)
    }

    return nil
  }

  private static func zoomTableAwareHTML(_ html: String) -> String {
    html
      .replacingOccurrences(
        of: #"(?is)</(?:td|th)>\s*<(?:td|th)\b[^>]*>"#,
        with: "<br />",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"(?is)</tr>\s*<tr\b[^>]*>"#,
        with: "<br />",
        options: .regularExpression
      )
  }

  private static func cleanedZoomReleaseText(_ lines: [String]) -> String {
    var normalizedLines = [String]()
    var skippingFullVersions = false

    for line in lines {
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedLine.isEmpty else { continue }

      if trimmedLine.range(
        of: #"^Full versions(?: for .+)?$"#,
        options: [.regularExpression, .caseInsensitive]) != nil
      {
        skippingFullVersions = true
        continue
      }

      if skippingFullVersions {
        if Self.looksLikeZoomReleaseNotesSectionStart(trimmedLine) {
          skippingFullVersions = false
        } else {
          continue
        }
      }

      if ["Type", "Feature title", "Description", "Platforms"].contains(trimmedLine) { continue }
      if trimmedLine.localizedCaseInsensitiveCompare("Type Feature title Description Platforms")
        == .orderedSame
      {
        continue
      }

      normalizedLines.append(trimmedLine)
    }

    var cleanedLines = [String]()
    var index = normalizedLines.startIndex
    while index < normalizedLines.endIndex {
      let line = normalizedLines[index]
      guard Self.looksLikeZoomFeatureRowStart(line) else {
        if !Self.isZoomPlatformOnlyLine(line) {
          cleanedLines.append(line)
        }
        index += 1
        continue
      }

      var endIndex = index + 1
      while endIndex < normalizedLines.endIndex,
        !Self.looksLikeZoomFeatureRowStart(normalizedLines[endIndex]),
        !Self.looksLikeZoomReleaseNotesSectionStart(normalizedLines[endIndex])
      {
        endIndex += 1
      }

      let block = Array(normalizedLines[index..<endIndex])
      let declaredPlatforms = block.dropFirst().flatMap { Self.zoomPlatformsIfOnlyLine($0) ?? [] }
      if declaredPlatforms.isEmpty || declaredPlatforms.contains("macos") {
        cleanedLines.append(contentsOf: block.filter { Self.zoomPlatformsIfOnlyLine($0) == nil })
      }
      index = endIndex
    }

    return cleanedLines.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func zoomArticleBodyHTML(fromHTML html: String) -> String? {
    let pattern =
      #"(?is)<script\b[^>]*\btype\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

    let matches = regex.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html))
    let decoder = JSONDecoder()
    for match in matches {
      guard let scriptRange = Range(match.range(at: 1), in: html) else { continue }

      let json = String(html[scriptRange])
      guard let data = json.data(using: .utf8) else { continue }

      if let article = try? decoder.decode(StructuredArticle.self, from: data),
        let articleBody = article.articleBody?.trimmingCharacters(in: .whitespacesAndNewlines),
        !articleBody.isEmpty
      {
        return articleBody
      }

      if let articles = try? decoder.decode([StructuredArticle].self, from: data),
        let articleBody = articles.compactMap(\.articleBody).first(where: {
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
      {
        return articleBody
      }
    }

    return nil
  }

  private static func looksLikeZoomReleaseBody(_ text: String) -> Bool {
    text.range(
      of:
        #"(?m)^(New, enhanced, and changed features|Resolved issues|Changed features|Security enhancements)\b"#,
      options: [.regularExpression, .caseInsensitive]) != nil
      || text.range(
        of: #"Show or hide icon labels|New or enhanced feature|Resolved an issue"#,
        options: [.regularExpression, .caseInsensitive]) != nil
  }

  private static func zoomReleaseTextWithVersionHeader(_ text: String, version: String?) -> String {
    guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines),
      !version.isEmpty,
      !text.hasPrefix("Zoom " + version)
    else {
      return text
    }

    return "Zoom \(version)\n\(text)"
  }

  private static func looksLikeZoomReleaseNotesSectionStart(_ line: String) -> Bool {
    line.range(
      of:
        #"^(New, enhanced, and changed features|Resolved issues|Changed features|Security enhancements)"#,
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  private static func looksLikeZoomFeatureRowStart(_ line: String) -> Bool {
    line.range(
      of: #"^(New or enhanced feature|Changed feature|Resolved issue|Security enhancement)\b"#,
      options: [.regularExpression, .caseInsensitive]
    ) != nil
  }

  private static func isZoomPlatformOnlyLine(_ line: String) -> Bool {
    Self.zoomPlatformsIfOnlyLine(line) != nil
  }

  private static func zoomPlatformsIfOnlyLine(_ line: String) -> [String]? {
    var remainder = line.lowercased()
    let platformPatterns: [(pattern: String, value: String)] = [
      (#"\bmacos\b"#, "macos"),
      (#"\bwindows\b"#, "windows"),
      (#"\blinux\b"#, "linux"),
      (#"\bandroid(?:\s*\(intune\))?"#, "android"),
      (#"\bios(?:\s*\(intune\))?"#, "ios"),
      (#"\bvisionos\b"#, "visionos"),
    ]
    var platforms = [String]()
    for platform in platformPatterns {
      if remainder.range(of: platform.pattern, options: .regularExpression) != nil {
        platforms.append(platform.value)
        remainder = remainder.replacingOccurrences(
          of: platform.pattern,
          with: " ",
          options: .regularExpression
        )
      }
    }
    remainder = remainder.replacingOccurrences(
      of: #"[\s,/*|&+()-]+"#, with: "", options: .regularExpression)
    return !platforms.isEmpty && remainder.isEmpty ? platforms : nil
  }
}
