// Copyright © 2026 Max Langer and ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import Combine
import Foundation
import SwiftUI

/// Owns preparation and the pending action, so dismissal or a late XPC reply
/// cannot accidentally start a download. The sheet remains visible through repair.
@MainActor
final class UpdateInstallHelperAlert: ObservableObject {
  static let shared = UpdateInstallHelperAlert()
  @Published var isPresented = false
  private enum State {
    case checking
    case needsSetup
    case needsApproval
    case failed(Error)

    init(error: Error) {
      switch error as? InstallHelperError {
      case .installHelperNotRegistered: self = .needsSetup
      case .installHelperRequiresApproval: self = .needsApproval
      default: self = .failed(error)
      }
    }
  }

  @Published private var state = State.needsSetup
  private var fallbackURL: URL?
  private var pendingUpdates: [() -> Void] = []
  private var preparation: (@MainActor () async throws -> Void)?
  private var checkTask: Task<Void, Never>?
  private let helper: any InstallHelperServicing
  private let workspace: any ApplicationWorkspace

  init(
    helper: any InstallHelperServicing = LiveInstallHelperService.shared,
    workspace: any ApplicationWorkspace = MacApplicationWorkspace.shared
  ) {
    self.helper = helper
    self.workspace = workspace
  }

  /// Queues a batch behind one live check, or shows an existing prerequisite
  /// failure until the user chooses to retry.
  func prepare(
    fallbackURL: URL, error: InstallHelperError? = nil,
    preparation: (@MainActor () async throws -> Void)? = nil,
    update: @escaping () -> Void
  ) {
    guard pendingUpdates.isEmpty else {
      pendingUpdates.append(update)
      return
    }
    self.fallbackURL = fallbackURL
    self.preparation = preparation
    pendingUpdates = [update]
    if let error {
      state = State(error: error)
      if AppStoreUpdateSettings.alwaysPerformManualUpdates.active {
        openAppStore()
        return
      }
    }
    isPresented = true
    if error == nil { check() }
  }

  var isChecking: Bool {
    if case .checking = state { return true }
    return false
  }

  var errorDetails: String? {
    guard case .failed(let error) = state else { return nil }
    return [error.localizedDescription, (error as? LocalizedError)?.failureReason]
      .compactMap { $0 }.joined(separator: "\n\n")
  }

  var title: String {
    switch state {
    case .checking: return "Checking Update Helper"
    case .needsSetup: return "Set Up App Store Updates"
    case .needsApproval: return "Allow App Store Updates"
    case .failed: return "Update Helper Unavailable"
    }
  }

  var message: String {
    switch state {
    case .checking:
      return "Checking that the helper is ready before downloading any updates."
    case .needsSetup:
      return
        "Latest needs an approved helper to install App Store updates. No updates will download until it is ready."
    case .needsApproval:
      return
        "Allow Latest in System Settings → General → Login Items & Extensions. Return here to continue automatically once the helper is ready."
    case .failed:
      return
        "Latest could not connect to its update helper. No downloads have started. Try checking again, or update using the App Store."
    }
  }

  var primaryTitle: String {
    switch state {
    case .checking: return "Checking…"
    case .needsSetup: return "Enable Helper"
    case .needsApproval: return "Open System Settings"
    case .failed: return "Check Again"
    }
  }

  func enableHelper() {
    switch state {
    case .needsSetup, .needsApproval: check(register: true)
    case .failed: check()
    case .checking: break
    }
  }

  func resumeIfAvailable() {
    guard case .needsApproval = state else { return }
    check()
  }

  private func check(register: Bool = false) {
    guard !pendingUpdates.isEmpty, checkTask == nil else { return }
    state = .checking
    checkTask = Task {
      do {
        if register { try helper.register() }
        if let preparation { try await preparation() } else { try await helper.prepareForUpdates() }
        guard !Task.isCancelled else { return }
        let updates = pendingUpdates
        clear()
        isPresented = false
        updates.forEach { $0() }
      } catch {
        guard !Task.isCancelled else { return }
        checkTask = nil
        state = State(error: error)
      }
    }
  }

  func openAppStore() {
    let url = fallbackURL
    cancel()
    if let url { workspace.open(url) }
  }

  func cancel() {
    checkTask?.cancel()
    clear()
    isPresented = false
  }

  private func clear() {
    fallbackURL = nil
    pendingUpdates = []
    preparation = nil
    checkTask = nil
    state = .needsSetup
  }
}

struct UpdateInstallHelperPresentation: ViewModifier {
  @ObservedObject var presenter: UpdateInstallHelperAlert = .shared
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage(AppStoreUpdateSettings.alwaysPerformManualUpdates.rawValue)
  private var alwaysOpenAppStore = false

  func body(content: Content) -> some View {
    content
      .sheet(
        isPresented: $presenter.isPresented,
        onDismiss: { if !presenter.isPresented { presenter.cancel() } }
      ) {
        VStack(alignment: .leading, spacing: 20) {
          HStack(spacing: 12) {
            Image(systemName: "shippingbox")
              .font(.system(size: 28)).foregroundStyle(.secondary)
            Text(presenter.title).font(.title2.bold())
          }
          Text(presenter.message).fixedSize(horizontal: false, vertical: true)
          if presenter.isChecking {
            HStack(spacing: 10) {
              ProgressView().controlSize(.small)
              Text("Checking and repairing helper…").foregroundStyle(.secondary)
            }
          }
          if let details = presenter.errorDetails {
            DisclosureGroup("Details") {
              Text(details)
                .font(.caption).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          Toggle("Always open App Store", isOn: $alwaysOpenAppStore)
          Divider()
          HStack {
            Button("Cancel", role: .cancel) { presenter.cancel() }
              .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Open App Store") { presenter.openAppStore() }
            Button(presenter.primaryTitle) { presenter.enableHelper() }
              .keyboardShortcut(.defaultAction)
              .disabled(presenter.isChecking)
          }
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .interactiveDismissDisabled(presenter.isChecking)
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { presenter.resumeIfAvailable() }
      }
  }
}
