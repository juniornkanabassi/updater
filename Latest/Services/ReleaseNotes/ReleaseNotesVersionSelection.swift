//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-09-05.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation

extension ReleaseNotesMarkup {
  static func relevantText(
    from text: String, version: String?, allowFirstSectionFallback: Bool,
    preferredSuffix: String? = nil
  ) -> String? {
    let lines = text.components(separatedBy: .newlines)

    guard !lines.isEmpty else { return nil }

    let versionCandidates = Self.versionCandidates(from: version)
    var startIndex: Int?

    if !versionCandidates.isEmpty {
      func matchers(preferredSuffix: String?) -> [NSRegularExpression] {
        versionCandidates.compactMap { version in
          let escapedVersion = NSRegularExpression.escapedPattern(for: version)
          let pattern: String
          if let preferredSuffix {
            let escapedSuffix = NSRegularExpression.escapedPattern(for: preferredSuffix)
            pattern = #"(^|[^\w.])v?\#(escapedVersion)\s+\#(escapedSuffix)([^\w]|\z)"#
          } else {
            pattern = #"(^|[^\w.])v?\#(escapedVersion)([^\w.]|\z)"#
          }
          return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        }
      }

      let standardMatchers = matchers(preferredSuffix: nil)
      let preferredMatchers = preferredSuffix.map { matchers(preferredSuffix: $0) } ?? []

      func matchingVersionIndex(
        requiresBoundary: Bool, matchers: [NSRegularExpression], requiresHeading: Bool = false
      ) -> Int? {
        for (index, line) in lines.enumerated() {
          guard !requiresHeading || line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
            !Self.looksLikeVersionNavigation(line, at: index, in: lines),
            !requiresBoundary || Self.looksLikeVersionBoundary(line)
          else { continue }

          let line = line.trimmingCharacters(in: .whitespaces)
          let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
          if matchers.contains(where: { regex in
            regex.firstMatch(in: line, range: lineRange) != nil
          }) {
            return index
          }
        }

        return nil
      }

      if preferredSuffix != nil {
        startIndex =
          matchingVersionIndex(requiresBoundary: true, matchers: preferredMatchers)
          ?? matchingVersionIndex(requiresBoundary: false, matchers: preferredMatchers)
      }

      startIndex =
        startIndex ?? matchingVersionIndex(
          requiresBoundary: true, matchers: standardMatchers, requiresHeading: true)
        ?? matchingVersionIndex(requiresBoundary: true, matchers: standardMatchers)
        ?? matchingVersionIndex(requiresBoundary: false, matchers: standardMatchers)
    }

    if startIndex == nil, allowFirstSectionFallback {
      startIndex = lines.firstIndex { line in
        Self.looksLikeReleaseBoundary(line)
      }
    }

    guard let startIndex else { return nil }
    let exactVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
    let startLine = lines[startIndex]
    let shouldEndAtVersionBoundary = Self.looksLikeVersionBoundary(startLine)
    var hasBody = false
    var endIndex = lines.endIndex
    for index in (startIndex + 1)..<lines.endIndex {
      let line = lines[index]
      let isImmediateDateAfterBareVersion = !hasBody && Self.looksLikeDateReleaseBoundary(line)

      let isBoundary =
        if shouldEndAtVersionBoundary {
          Self.looksLikeVersionBoundary(line)
            || (Self.looksLikeDateReleaseBoundary(line) && !isImmediateDateAfterBareVersion)
        } else {
          Self.looksLikeReleaseBoundary(line)
        }

      if isBoundary
        && (hasBody || !(exactVersion.map { line.localizedCaseInsensitiveContains($0) } ?? false))
      {
        endIndex = index
        break
      }
      if !line.trimmingCharacters(in: .whitespaces).isEmpty && !isImmediateDateAfterBareVersion {
        hasBody = true
      }
    }

    let selectedLines = lines[startIndex..<endIndex]
    guard !selectedLines.isEmpty else { return nil }

    return selectedLines.joined(separator: "\n")
  }

  static func lineContainsVersionCandidate(_ line: String, candidates: [String]) -> Bool {
    candidates.contains { candidate in
      let escapedCandidate = NSRegularExpression.escapedPattern(for: candidate)
      return line.range(
        of: #"(^|[^\w.])v?\#(escapedCandidate)([^\w.]|\z)"#,
        options: [.regularExpression, .caseInsensitive]) != nil
    }
  }

  static func versionCandidates(from version: String?) -> [String] {
    guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty
    else {
      return []
    }

    var candidates = [version]
    var parts = version.split(separator: ".").map(String.init)
    while parts.count > 2, parts.last == "0" {
      parts.removeLast()
      candidates.append(parts.joined(separator: "."))
    }
    return candidates
  }

  private static func looksLikeReleaseBoundary(_ line: String) -> Bool {
    Self.looksLikeVersionBoundary(line) || Self.looksLikeDateReleaseBoundary(line)
  }

  static func looksLikeDateReleaseBoundary(_ line: String) -> Bool {
    let line = line.replacingOccurrences(
      of: #"^\s*#{1,6}\s+"#, with: "", options: .regularExpression
    )
    .trimmingCharacters(in: .whitespaces)
    return line.range(
      of:
        #"^(?:[A-Z][a-z]+ \d{1,2},? \d{4}|\d{4} [A-Z][a-z]+ \d{1,2}|\d{4}-\d{2}-\d{2})(?:\s*(?:·.*|version\b.*))?\s*$"#,
      options: .regularExpression) != nil
  }

  static func looksLikeVersionBoundary(_ line: String) -> Bool {
    let line = line.trimmingCharacters(in: .whitespaces)
    let label = cleaningInlineMarkdown(in: line).replacingOccurrences(
      of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
    guard label.count < 180, !label.hasPrefix("-"), !label.hasPrefix("•"),
      !label.lowercased().hasPrefix("download"),
      let range = label.range(
        of: #"(?i)^(?:[^\d\n]{0,65})v?\d+(?:\.\d+)+(?:[a-z]+\d*)?"#, options: .regularExpression)
    else { return false }
    let suffix = label[range.upperBound...].trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("#") { return true }
    if suffix.isEmpty || suffix.first.map({ ":(-–—".contains($0) }) == true { return true }
    if ["desktop", "mobile", "release", "release notes"].contains(suffix.lowercased()) {
      return true
    }
    return suffix.range(of: #"^[A-Z][a-z]+ \d{1,2},? \d{4}"#, options: .regularExpression) != nil
  }

  private static func looksLikeVersionNavigation(_ line: String, at index: Int, in lines: [String])
    -> Bool
  {
    if Self.looksLikeDenseVersionNavigation(line) {
      return true
    }

    guard Self.isBareVersionLine(line) else { return false }

    if lines.indices.contains(index + 1), Self.looksLikeDateReleaseBoundary(lines[index + 1]) {
      return false
    }

    if index > lines.startIndex, Self.isBareVersionLine(lines[index - 1]) {
      return true
    }

    if lines.indices.contains(index + 1), Self.isBareVersionLine(lines[index + 1]) {
      return true
    }

    return index > lines.startIndex
      && Self.versionNavigationWords.contains(lines[index - 1].lowercased())
  }

  private static func looksLikeDenseVersionNavigation(_ line: String) -> Bool {
    let matches = line.matches(of: /\bv?\d+(?:\.\d+){1,}\b/)
    guard matches.count >= 4 else { return false }

    let words = line.matches(of: /[A-Za-z]{3,}/).map { String(line[$0.range]) }
    let meaningfulWords = words.filter { !Self.versionNavigationWords.contains($0.lowercased()) }

    return meaningfulWords.count <= 2
  }

  static func isBareVersionLine(_ line: String) -> Bool {
    line.range(of: #"^v?\d+(\.\d+){1,}$"#, options: [.regularExpression, .caseInsensitive]) != nil
  }
}
