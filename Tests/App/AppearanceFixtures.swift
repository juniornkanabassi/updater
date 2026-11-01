//
//  AppearanceFixture.swift
//  Latest
//
//  Created by ertyoii on 19.07.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-01.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI

@testable import Latest

private typealias App = Latest.App

/// Deterministic fixtures used by the detail and settings appearance checks.
///
/// Only production controls belong here. Main-window and sidebar coverage uses
/// LatestMainWindowScene with offline models, never a second UI implementation.
struct AppearanceFixtureScenario: Identifiable {
  enum Surface {
    case detail(DetailState)
    case locations
  }

  enum DetailState {
    case releaseNotes
    case empty
    case loading
    case error
  }

  let id: String
  let surface: Surface
  let size: CGSize
  let colorScheme: ColorScheme
  let controlActiveState: ControlActiveState
  let tint: Color
  let contrast: ColorSchemeContrast
  let reduceTransparency: Bool
  let dynamicTypeSize: DynamicTypeSize
  let locale: Locale
  let layoutDirection: LayoutDirection

  init(
    _ id: String,
    surface: Surface,
    size: CGSize = AppearanceFixtureMetrics.defaultWindowSize,
    colorScheme: ColorScheme = .light,
    controlActiveState: ControlActiveState = .active,
    tint: Color = .blue,
    contrast: ColorSchemeContrast = .standard,
    reduceTransparency: Bool = false,
    dynamicTypeSize: DynamicTypeSize = .large,
    locale: Locale = Locale(identifier: "en_US"),
    layoutDirection: LayoutDirection = .leftToRight
  ) {
    self.id = id
    self.surface = surface
    self.size = size
    self.colorScheme = colorScheme
    self.controlActiveState = controlActiveState
    self.tint = tint
    self.contrast = contrast
    self.reduceTransparency = reduceTransparency
    self.dynamicTypeSize = dynamicTypeSize
    self.locale = locale
    self.layoutDirection = layoutDirection
  }

  static let regressionCases: [AppearanceFixtureScenario] = [
    AppearanceFixtureScenario("main-default-light", surface: .detail(.releaseNotes)),
    AppearanceFixtureScenario(
      "main-minimum-dark-empty",
      surface: .detail(.empty),
      size: AppearanceFixtureMetrics.minimumWindowSize,
      colorScheme: .dark,
      tint: .green
    ),
    AppearanceFixtureScenario(
      "main-inactive-graphite",
      surface: .detail(.releaseNotes),
      controlActiveState: .inactive,
      tint: .gray
    ),
    AppearanceFixtureScenario(
      "main-increased-contrast-orange",
      surface: .detail(.releaseNotes),
      colorScheme: .dark,
      tint: .orange,
      contrast: .increased
    ),
    AppearanceFixtureScenario(
      "main-reduce-transparency-purple",
      surface: .detail(.loading),
      tint: .purple,
      reduceTransparency: true
    ),
    AppearanceFixtureScenario(
      "main-large-text-error",
      surface: .detail(.error),
      dynamicTypeSize: .accessibility1
    ),
    AppearanceFixtureScenario(
      "main-rtl-long-localization",
      surface: .detail(.releaseNotes),
      locale: Locale(identifier: "ar"),
      layoutDirection: .rightToLeft
    ),
    AppearanceFixtureScenario("locations-light", surface: .locations),
    AppearanceFixtureScenario(
      "locations-dark-inactive",
      surface: .locations,
      colorScheme: .dark,
      controlActiveState: .inactive,
      tint: .pink
    ),
    AppearanceFixtureScenario(
      "locations-contrast-large-rtl",
      surface: .locations,
      contrast: .increased,
      dynamicTypeSize: .accessibility1,
      locale: Locale(identifier: "ar"),
      layoutDirection: .rightToLeft
    ),
  ]
}

enum AppearanceFixtureMetrics {
  static let defaultWindowSize = CGSize(width: 768, height: 516)
  static let minimumWindowSize = CGSize(width: 560, height: 360)
  static let sidebarWidth: CGFloat = 308
  static let detailHeaderHeight: CGFloat = 79
  static let locationsContentSize = CGSize(width: 440, height: 296)
  static let locationsTableSize = CGSize(width: 400, height: 200)

  static func detailFrame(in size: CGSize) -> CGRect {
    let sidebarWidth = min(self.sidebarWidth, size.width)
    return CGRect(
      x: sidebarWidth, y: 0, width: max(0, size.width - sidebarWidth), height: size.height)
  }
}

struct AppearanceFixtureView: View {
  let scenario: AppearanceFixtureScenario

  var body: some View {
    content
      .frame(width: scenario.size.width, height: scenario.size.height)
      .environment(\.colorScheme, scenario.colorScheme)
      .environment(\.controlActiveState, scenario.controlActiveState)
      .environment(\.dynamicTypeSize, scenario.dynamicTypeSize)
      .environment(\.locale, scenario.locale)
      .environment(\.layoutDirection, scenario.layoutDirection)
      .tint(scenario.tint)
      .contrast(scenario.contrast == .increased ? 1.18 : 1)
      .background {
        if scenario.reduceTransparency {
          Color(nsColor: .windowBackgroundColor)
        }
      }
  }

  @ViewBuilder
  private var content: some View {
    switch scenario.surface {
    case .detail(let state):
      // Preserve the reviewed detail coordinates. The blank area replaces the
      // old mock sidebar, which was never part of the pixel comparison.
      HStack(spacing: 0) {
        Color.clear.frame(width: AppearanceFixtureMetrics.sidebarWidth)
        Divider()
        DetailFixture(state: state)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .background(.background)
    case .locations:
      LocationsFixture()
    }
  }
}

private struct DetailFixture: View {
  let state: AppearanceFixtureScenario.DetailState

  var body: some View {
    ReleaseNotesDetailSurface(app: fixtureApp, contentState: contentState)
  }

  private var contentState: ReleaseNotesDetailContentState {
    switch state {
    case .releaseNotes:
      return .text(fixtureReleaseNotes)
    case .empty:
      return .message(
        ReleaseNotesMessage(
          title: "No Release Notes",
          description: "Release notes are not available for this application."
        ))
    case .loading:
      return .loading
    case .error:
      return .message(
        ReleaseNotesMessage(
          title: "Release Notes Unavailable",
          description: "The server response could not be rendered. Try checking for updates again."
        ))
    }
  }

  private var fixtureApp: App {
    let bundle = App.Bundle(
      version: Version(versionNumber: "3.12.17", buildNumber: nil),
      name: "Cursor",
      bundleIdentifier: "com.example.cursor",
      // Both renderers must resolve the exact same file, not their separately
      // compiled host bundles (whose NSWorkspace icon representations differ).
      fileURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
      source: .homebrew
    )
    return App(bundle: bundle, update: nil, isIgnored: false)
  }

  private var fixtureReleaseNotes: ReleaseNotesContent {
    let text = NSMutableAttributedString(string: "Improvements to Cursor\n\n")
    text.addAttribute(
      .font,
      value: NSFont.systemFont(ofSize: 20, weight: .semibold),
      range: NSRange(location: 0, length: 22)
    )
    text.append(
      NSAttributedString(
        string:
          "Cursor now shares a plan before it starts, preserves context across repositories, and reports progress with clearer status updates.\n\n"
      ))
    text.append(
      NSAttributedString(
        string: "Interaction improvements\n",
        attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
      ))
    text.append(
      NSAttributedString(
        string:
          "Links remain selectable, keyboard copy continues to work, and paragraph spacing stays stable for long release notes.\n\n"
      ))
    text.append(
      NSAttributedString(
        string: "Read the full changelog",
        attributes: [.link: URL(string: "https://example.com/changelog")!]
      ))
    return ReleaseNotesLegacyBridge.content(from: text)
  }
}

private struct LocationsFixture: View {
  private static let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
  private static let utilitiesURL = URL(
    fileURLWithPath: "/Applications/Utilities", isDirectory: true)
  private static let archiveURL = URL(
    fileURLWithPath: "/Volumes/Archived Applications", isDirectory: true)
  private static let urls = [applicationsURL, utilitiesURL, archiveURL]

  // The synthesized $selection binding is consumed by SettingsLocationsPane.
  // swiftlint:disable:next unused_declaration
  @State private var selection: URL? = applicationsURL

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Check apps from:")

      DirectoryLocationsTable(
        urls: Self.urls,
        selection: $selection,
        loadDetails: Self.loadDetails
      )
      .frame(
        width: AppearanceFixtureMetrics.locationsTableSize.width,
        height: AppearanceFixtureMetrics.locationsTableSize.height
      )

      ControlGroup {
        Button("Add Location", systemImage: "plus") {}
          .labelStyle(.iconOnly)
        Button("Remove Location", systemImage: "minus") {}
          .labelStyle(.iconOnly)
      }
      .controlSize(.small)
      .fixedSize()
    }
    .padding(.horizontal, 20)
    .padding(.top, 19)
    .frame(
      width: AppearanceFixtureMetrics.locationsContentSize.width,
      height: AppearanceFixtureMetrics.locationsContentSize.height,
      alignment: .topLeading
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }

  private static func loadDetails(for url: URL) async -> DirectoryLocationDetails {
    switch url {
    case utilitiesURL:
      try? await Task.sleep(for: .seconds(30))
      return DirectoryLocationDetails(isReachable: true, appCount: 12)
    case archiveURL:
      return DirectoryLocationDetails(isReachable: false, appCount: 0)
    default:
      return DirectoryLocationDetails(isReachable: true, appCount: 38)
    }
  }
}
