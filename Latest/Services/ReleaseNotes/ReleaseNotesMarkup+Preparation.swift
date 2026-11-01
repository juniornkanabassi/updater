// Copyright © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

extension ReleaseNotesMarkup {
  static func structuredMarkdown(_ markdown: String) -> String {
    let cleaned = markdown.replacingOccurrences(
      of: #"(?m)^(\s*)[-*•]\s+[-*•]\s+"#, with: "$1- ", options: .regularExpression
    )
    .replacingOccurrences(of: #"(?m)^(\s*)[•◦]\s+"#, with: "$1- ", options: .regularExpression)
    return cleaned.components(separatedBy: .newlines).map { line in
      let label = line.trimmingCharacters(in: .whitespaces)
      if !label.hasPrefix("#"), ReleaseNotesMarkup.looksLikeVersionBoundary(label) {
        return "## " + label
      }
      if [
        "Features", "New", "Improvements", "Bug Fixes", "Bug fixes", "Fixes", "Changes",
        "Highlights", "Resolved issues", "Security", "Security Fixes and Rewards",
        "No longer broken", "Maintenance",
      ].contains(label) {
        return "### " + label
      }
      return line
    }.joined(separator: "\n")
  }

  static func prefersMarkdown(_ string: String) -> Bool {
    !string.containsHTMLTag
      && string.range(
        of: #"(?m)^\s*(?:#{1,6} |[-*•◦] |\d+\. |```)|\[[^\]]+\]\(|\*|_|`"#,
        options: .regularExpression) != nil
  }
}
