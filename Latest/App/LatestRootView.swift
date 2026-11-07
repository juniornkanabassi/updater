//
//  LatestRootView.swift
//  Latest
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import Combine
import SwiftUI

struct LatestRootView: View {
  let environment: AppEnvironment
  private let detailViewModel: ReleaseNotesDetailViewModel
  private let history: UpdateHistoryStore
  @StateObject private var receipt: UpdateReceiptModel

  @FocusState private var focus: SidebarFocus?
  @ObservedObject private var updatesViewModel: UpdatesListViewModel
  @ObservedObject private var searchFocusController: SearchFocusController
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  init(
    environment: AppEnvironment,
    detailViewModel: ReleaseNotesDetailViewModel = ReleaseNotesDetailViewModel(),
    history: UpdateHistoryStore = .shared,
    receipt: UpdateReceiptModel? = nil
  ) {
    self.environment = environment
    self.detailViewModel = detailViewModel
    self.history = history
    _receipt = StateObject(wrappedValue: receipt ?? UpdateReceiptModel(history: history))
    _updatesViewModel = ObservedObject(wrappedValue: environment.updatesListViewModel)
    _searchFocusController = ObservedObject(wrappedValue: environment.searchFocusController)
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      UpdatesSidebarView(
        viewModel: updatesViewModel,
        searchFocusController: environment.searchFocusController
      )
      .navigationSplitViewColumnWidth(min: 260, ideal: VisualMetrics.sidebarIdealWidth, max: 480)
    } detail: {
      VStack(spacing: 0) {
        if let message = receipt.message {
          UpdateReceiptBanner(message: message, dismiss: receipt.dismiss)
        }
        ReleaseNotesDetailView(
          updatesViewModel: updatesViewModel,
          detailViewModel: detailViewModel, history: history
        )
      }
      .frame(minWidth: VisualMetrics.detailMinWidth)
      .navigationTitle("Updates")
    }
    .environment(\.windowFocus, $focus)
    .onChange(of: searchFocusController.request) { _, request in
      if request != nil { columnVisibility = .all }
    }
    .onAppear {
      if searchFocusController.hasPendingRequest { columnVisibility = .all }
    }
    .modifier(UpdateInstallHelperPresentation())
    .toolbar {
      UpdatesToolbar(
        service: environment.updateCheckingService, summary: environment.menuBar,
        reload: { environment.commands.reload() },
        updateAll: { environment.commands.updateAll() })
    }
  }
}

/// Receipts follow verified history events, independently of list selection or filtering.
@MainActor
final class UpdateReceiptModel: ObservableObject {
  @Published private(set) var count = 0
  @Published private(set) var latest: UpdateHistoryEntry?
  private var observation: AnyCancellable?

  init(history: UpdateHistoryStore) {
    observation = NotificationCenter.default.publisher(
      for: UpdateHistoryStore.didRecordNotification, object: history
    )
    .compactMap { $0.userInfo?[UpdateHistoryStore.entryKey] as? UpdateHistoryEntry }
    .receive(on: DispatchQueue.main)
    .sink { [weak self] entry in
      guard case .updated = entry.outcome, let self else { return }
      self.count += 1
      if let latest = self.latest, latest.date > entry.date { return }
      self.latest = entry
    }
  }

  var message: String? {
    guard let latest, case .updated(_, let version) = latest.outcome else { return nil }
    let name = URL(fileURLWithPath: latest.appPath).deletingPathExtension().lastPathComponent
    let result = "Updated \(name) to \(version)."
    return count == 1 ? result : "\(count) updates completed. \(result)"
  }

  func dismiss() {
    count = 0
    latest = nil
  }
}

struct UpdateReceiptBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
      Label(message, systemImage: "checkmark.circle")
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .frame(width: Space.xxl, height: Space.xxl)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Dismiss update confirmation")
      .accessibilityLabel("Dismiss update confirmation")
      .accessibilityIdentifier("updates.receipt.dismiss")
    }
    .font(.callout)
    .padding(.horizontal, VisualMetrics.detailHeaderHorizontalPadding)
    .padding(.vertical, Space.md)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("updates.receipt")
    Divider()
  }
}
