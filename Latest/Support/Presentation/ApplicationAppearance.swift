//
//  ApplicationAppearance.swift
//  Latest
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI

enum ApplicationAppearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  static let storageKey = "applicationAppearance"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system:
      "System"
    case .light:
      "Light"
    case .dark:
      "Dark"
    }
  }

  var appKitAppearanceName: NSAppearance.Name? {
    switch self {
    case .system:
      nil
    case .light:
      .aqua
    case .dark:
      .darkAqua
    }
  }

  @MainActor
  func apply(to application: NSApplication) {
    guard application.appearance?.name != appKitAppearanceName else { return }
    application.appearance = appKitAppearanceName.flatMap(NSAppearance.init(named:))
  }

  static func resolve(_ rawValue: String) -> Self {
    Self(rawValue: rawValue) ?? .system
  }
}
struct ApplicationAppearanceModifier: ViewModifier {
  let appearance: ApplicationAppearance

  func body(content: Content) -> some View {
    content
      .onAppear {
        appearance.apply(to: NSApplication.shared)
      }
      .onChange(of: appearance) { _, newAppearance in
        newAppearance.apply(to: NSApplication.shared)
      }
  }
}
