//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-09-05.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation

enum NavicatReleaseNotesExtractor {
  static func navicatMacReleaseText(fromHTML html: String, version: String?, pageURL: URL)
    -> String?
  {
    guard pageURL.host?.localizedCaseInsensitiveContains("navicat.com") == true,
      let text = ReleaseNotesMarkup.plainText(fromHTML: html)
    else {
      return nil
    }

    let candidates = ReleaseNotesMarkup.versionCandidates(from: version)
    guard !candidates.isEmpty else { return nil }
    let lines = text.components(separatedBy: .newlines).compactMap { line -> String? in
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedLine.isEmpty ? nil : trimmedLine
    }

    guard
      let startIndex = lines.firstIndex(where: { line in
        line.localizedCaseInsensitiveContains("(macOS)")
          && line.localizedCaseInsensitiveContains("version")
          && ReleaseNotesMarkup.lineContainsVersionCandidate(line, candidates: candidates)
      })
    else {
      return nil
    }

    var endIndex = lines.endIndex
    for index in (startIndex + 1)..<lines.endIndex {
      let line = lines[index]
      let isPlatformReleaseHeading =
        line.localizedCaseInsensitiveContains("version")
        && (line.localizedCaseInsensitiveContains("(Windows)")
          || line.localizedCaseInsensitiveContains("(macOS)")
          || line.localizedCaseInsensitiveContains("(Linux)"))
      if isPlatformReleaseHeading || line.hasPrefix("To upgrade,")
        || ReleaseNotesMarkup.looksLikeDateReleaseBoundary(line)
      {
        endIndex = index
        break
      }
    }

    let releaseText = lines[startIndex..<endIndex].joined(separator: "\n")
    guard ReleaseNotesMarkup.isUsefulReleaseNotesText(releaseText, relevantVersion: version) else {
      return nil
    }

    return releaseText
  }
}
