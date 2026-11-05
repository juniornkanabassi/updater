// Fork contributions © 2026 ertyoii.
// Licensed under GPL-3.0; see LICENSE.md.

import ImageIO
import SwiftUI

struct AboutView: View {
  private static let icon: CGImage? = {
    guard
      let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
      let source = CGImageSourceCreateWithURL(url as CFURL, nil)
    else { return nil }
    let index =
      (0..<CGImageSourceGetCount(source)).max { lhs, rhs in
        func width(at index: Int) -> Int {
          let properties =
            CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
          return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        }
        return width(at: lhs) < width(at: rhs)
      } ?? 0
    return CGImageSourceCreateImageAtIndex(source, index, nil)
  }()

  var body: some View {
    VStack(spacing: Space.sm) {
      Group {
        if let icon = Self.icon {
          Image(decorative: icon, scale: 1)
            .resizable()
        } else {
          Image(systemName: "arrow.down.app.fill")
            .resizable()
            .foregroundStyle(.tint)
        }
      }
      .scaledToFit()
      .frame(width: 80, height: 80)
      .accessibilityLabel("Updater icon")
      .padding(.bottom, Space.sm)

      Text("Updater")
        .font(.title2.bold())

      Text("Version \(version)")
        .foregroundStyle(.secondary)

      VStack(spacing: 2) {
        Text("Based on Latest by Max Langer and the Ertyoii fork")
        Text("Licensed under GPL-3.0")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(.top, Space.md)
    }
    .padding(Space.xxl)
    .frame(width: 320)
    .toolbar(removing: .title)
    .containerBackground(.ultraThinMaterial, for: .window)
  }

  private var version: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    return build.isEmpty ? version : "\(version) (\(build))"
  }
}
