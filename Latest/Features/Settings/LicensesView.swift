// Fork contributions © 2026 ertyoii.
// Licensed under GPL-3.0; see LICENSE.md.

import SwiftUI

struct LicensesView: View {
  private enum License: String, CaseIterable {
    case latest = "Latest"
    case sparkle = "Sparkle"

    var resource: (name: String, extension: String) {
      switch self {
      case .latest: ("LICENSE", "md")
      case .sparkle: ("SparkleLicense", "txt")
      }
    }

    var text: String {
      let resource = resource
      guard
        let url = Bundle.main.url(forResource: resource.name, withExtension: resource.extension),
        let text = try? String(contentsOf: url, encoding: .utf8)
      else { return "License resource unavailable." }
      return text
    }
  }

  @State private var selectedLicense = License.latest

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Latest by Max Langer and contributors")
          .font(.headline)
        Text("Fork modifications © 2026 ertyoii. Modified October 3, 2026.")
        Text(
          "Distributed under GNU GPL version 3. You may redistribute and modify this software under that license. No warranty."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 16) {
          Link(
            "Original project", destination: URL(string: "https://github.com/mangerlahn/Latest")!)
          Link("Fork source", destination: URL(string: "https://github.com/Ertyoii/Latest")!)
        }
      }

      Picker("License", selection: $selectedLicense) {
        ForEach(License.allCases, id: \.self) { license in
          Text(license.rawValue).tag(license)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)

      ScrollView {
        Text(verbatim: selectedLicense.text)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      .id(selectedLicense)
      .background(.background, in: .rect(cornerRadius: 8))
    }
    .padding(20)
    .frame(minWidth: 480, minHeight: 400)
  }
}
