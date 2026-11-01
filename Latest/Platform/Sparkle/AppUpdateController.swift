//
//  AppUpdateController.swift
//  Latest
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation

@MainActor
struct AppUpdateController {
  private let workspace: any ApplicationWorkspace

  init(workspace: any ApplicationWorkspace = MacApplicationWorkspace.shared) {
    self.workspace = workspace
  }

  /// This source-built fork has no signed appcast; releases belong to the fork.
  func checkForAppUpdates() {
    guard let url = URL(string: "https://github.com/Ertyoii/Latest/releases") else { return }
    workspace.open(url)
  }
}
