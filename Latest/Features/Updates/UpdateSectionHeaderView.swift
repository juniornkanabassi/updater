//
//  UpdateSectionHeaderView.swift
//  Latest
//
//  Created by ertyoii on 31.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI

/// The table still owns pinned group-row behavior; SwiftUI draws its content.
struct UpdateSectionHeaderView: View {
  let section: AppListSnapshot.Section

  var body: some View {
    Text(Self.title(for: section))
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: VisualMetrics.sectionHeaderHeight - 10)
      .padding(.leading, 22)
      .padding(.trailing, 38)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .offset(y: 1.5)
  }

  private static let numberFormatter = NumberFormatter()

  private static func title(for section: AppListSnapshot.Section) -> AttributedString {
    let count = numberFormatter.string(from: section.numberOfApps as NSNumber) ?? "0"
    let format = NSLocalizedString(
      "SectionTitle",
      comment:
        "The title of a section divider in the app list. The first placeholder is the name of the section. The value in paranthesis describes how many apps are in that section, number of apps is inserted in the second placeholder. Use the HTML underline tag <u> to mark the deemphasized part of the text, which should be the count. Example: 'Installed Apps (42)'"
    )
    let sectionText = String(format: format, section.title, count)

    // Localizations mark the count with <u>; keep their ordering and punctuation
    // while applying SwiftUI attributes within a single text baseline.
    guard let opening = sectionText.range(of: "<u>"),
      let closing = sectionText.range(of: "</u>", range: opening.upperBound..<sectionText.endIndex)
    else {
      return styled(sectionText, count: false)
    }
    return styled(String(sectionText[..<opening.lowerBound]), count: false)
      + styled(String(sectionText[opening.upperBound..<closing.lowerBound]), count: true)
      + styled(String(sectionText[closing.upperBound...]), count: false)
  }

  private static func styled(_ text: String, count: Bool) -> AttributedString {
    var text = AttributedString(text)
    text.font = .system(size: count ? 11 : 13, weight: count ? .bold : .medium)
    text.foregroundColor = Color(nsColor: count ? .tertiaryLabelColor : .secondaryLabelColor)
    return text
  }
}
