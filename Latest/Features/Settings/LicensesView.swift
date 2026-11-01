// Fork contributions © 2026 ertyoii.
// Licensed under GPL-3.0; see LICENSE.md.

import SwiftUI

struct LicensesView: View {
  private enum License: String, CaseIterable {
    case updater = "Updater"
    case sparkle = "Sparkle"

    var resource: (name: String, extension: String) {
      switch self {
      case .updater: ("LICENSE", "md")
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

  @State private var selectedLicense = License.updater

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Updater is based on Latest by Max Langer and the Ertyoii fork")
          .font(.headline)
        Text("Modifications © 2026 Junior Nkana Bassi. Upstream notices are retained.")
        Text(
          "Distributed under GNU GPL version 3. You may redistribute and modify this software under that license. No warranty."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 16) {
          Link(
            "Latest by Max Langer",
            destination: URL(string: "https://github.com/mangerlahn/Latest")!)
          Link("Ertyoii fork", destination: URL(string: "https://github.com/Ertyoii/Latest")!)
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
