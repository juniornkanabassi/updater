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

  @AppStorage(MenuBarViewModel.showsItemKey) private var showsMenuBarItem = true
  @NSApplicationDelegateAdaptor(UpdaterAppDelegate.self) private var appDelegate
  @StateObject private var environment: AppEnvironment

  init() {
    // Built now, not lazily, so it is listening before launch finishes.
    let environment = AppEnvironment.live()
    _environment = StateObject(wrappedValue: environment)
  }

  var body: some Scene {
    LatestMainWindowScene(id: "main") {
      LatestRootView(environment: environment)
        .modifier(ApplicationAppearanceModifier(appearance: appearance))
        .modifier(MainWindowOpenerCapture())
        .onAppear { environment.start() }  // idempotent; launch normally started it already
    }
    // Started by the CLI or MCP (`--headless`): no window; the menu bar item and socket run.
    .defaultLaunchBehavior(
      CommandLine.arguments.contains("--headless") ? .suppressed : .automatic
    )
    .commands {
      LatestCommands(
        appCommands: environment.commands,
        updatesViewModel: environment.updatesListViewModel,
        updateCheckingService: environment.updateCheckingService
      )
    }

    MenuBarExtra(isInserted: $showsMenuBarItem) {
      MenuBarContentView(
        model: environment.menuBar, checking: environment.updateCheckingService,
        select: { environment.updatesListViewModel.select($0) })
    } label: {
      MenuBarLabel(model: environment.menuBar)
    }

    Settings {
      SettingsRootView(viewModel: environment.settingsViewModel)
        .modifier(ApplicationAppearanceModifier(appearance: appearance))
    }
    .windowResizability(.contentSize)

    Window("About Updater", id: "about") {
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
    Window("Updater", id: id) {
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
