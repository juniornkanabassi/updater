//
//  LatestApplication.swift
//  Latest
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import SwiftUI

struct LatestApplication: SwiftUI.App {
  @AppStorage(ApplicationAppearance.storageKey)
  private var appearanceRawValue = ApplicationAppearance.system.rawValue

  @StateObject private var environment: AppEnvironment
  private let appUpdateController = AppUpdateController()

  init() {
    _environment = StateObject(wrappedValue: .live())
  }

  var body: some Scene {
    LatestMainWindowScene(id: "main") {
      LatestRootView(environment: environment)
        .modifier(ApplicationAppearanceModifier(appearance: appearance))
        .onAppear {
          environment.start()
        }
        .onDisappear {
          environment.stop()
        }
    }
    .commands {
      LatestCommands(
        appCommands: environment.commands,
        updatesViewModel: environment.updatesListViewModel,
        updateCheckingService: environment.updateCheckingService,
        appUpdateController: appUpdateController
      )
    }

    Settings {
      SettingsRootView(viewModel: environment.settingsViewModel)
        .modifier(ApplicationAppearanceModifier(appearance: appearance))
    }
    .windowResizability(.contentSize)

    Window("About Latest", id: "about") {
      AboutView()
        .modifier(ApplicationAppearanceModifier(appearance: appearance))
        .windowMinimizeBehavior(.disabled)
    }
    .windowResizability(.contentSize)
    .restorationBehavior(.disabled)
    .defaultLaunchBehavior(.suppressed)

    Window("Licenses", id: "licenses") {
      LicensesView()
        .modifier(ApplicationAppearanceModifier(appearance: appearance))
    }
    .defaultSize(width: 560, height: 480)
    .windowResizability(.contentMinSize)
    .restorationBehavior(.disabled)
    .defaultLaunchBehavior(.suppressed)
  }

  private var appearance: ApplicationAppearance {
    ApplicationAppearance.resolve(appearanceRawValue)
  }
}

/// Shared by the runnable app and full-window tests so native window styling
/// cannot drift into a separately maintained test approximation.
struct LatestMainWindowScene<Content: View>: Scene {
  let id: String
  @ViewBuilder var content: Content

  var body: some Scene {
    Window("Latest", id: id) {
      content.frame(
        minWidth: VisualMetrics.mainWindowMinWidth,
        minHeight: VisualMetrics.mainWindowMinHeight)
    }
    .defaultSize(
      width: VisualMetrics.mainWindowDefaultWidth,
      height: VisualMetrics.mainWindowDefaultHeight
    )
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unified)
  }
}
