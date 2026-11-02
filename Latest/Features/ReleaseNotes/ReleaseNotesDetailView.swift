//
//  ReleaseNotesDetailView.swift
//  Latest
//
//  Created by ertyoii on 31.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI

struct ReleaseNotesDetailView: View {
  @ObservedObject var updatesViewModel: UpdatesListViewModel
  @StateObject private var detailViewModel: ReleaseNotesDetailViewModel

  init(
    updatesViewModel: UpdatesListViewModel,
    detailViewModel: ReleaseNotesDetailViewModel = ReleaseNotesDetailViewModel()
  ) {
    self.updatesViewModel = updatesViewModel
    _detailViewModel = StateObject(wrappedValue: detailViewModel)
  }

  var body: some View {
    ReleaseNotesDetailSurface(
      app: detailViewModel.app,
      contentState: detailViewModel.contentState,
      updating: updatesViewModel.updating,
      overview: DetailOverview(snapshot: updatesViewModel.snapshot)
    )
    .task(id: updatesViewModel.selectedApp.map(ObjectIdentifier.init)) {
      detailViewModel.display(
        updatesViewModel.selectedApp,
        waitForSelectionToSettle: updatesViewModel.isKeyboardSelection)
    }
    .onReceive(
      NotificationCenter.default.publisher(for: ReleaseNotesSourceCatalog.didRefreshNotification)
    ) { _ in
      // The selected app can remain unchanged after discovery settles. A late
      // catalog activation must still retry its notes with the new cache key.
      detailViewModel.display(
        updatesViewModel.selectedApp,
        waitForSelectionToSettle: updatesViewModel.isKeyboardSelection)
    }
    .transaction { transaction in
      transaction.animation = nil
      transaction.disablesAnimations = true
    }
  }

}

/// What the detail pane shows with no app selected: the state of the whole list.
enum DetailOverview: Equatable {
  case lookingForApps
  case checking
  case offline
  case upToDate(checked: Int)
  case chooseApp

  init(snapshot: AppListSnapshot) {
    let apps = snapshot.apps
    if apps.isEmpty {
      self = .lookingForApps
    } else if snapshot.checkingGeneration != nil {
      self = .checking
    } else if apps.contains(where: \.isActionable) {
      self = .chooseApp
    } else if !apps.contains(where: { $0.remoteVersion != nil }),
      apps.contains(where: { ($0.error as NSError?)?.domain == NSURLErrorDomain })
    {
      // shortcut: offline is inferred from every check failing with a URL error; switch to
      // NWPathMonitor if checks start failing for other reasons while online.
      self = .offline
    } else {
      self = .upToDate(checked: apps.filter { $0.remoteVersion != nil }.count)
    }
  }
}

struct ReleaseNotesDetailSurface: View {
  let app: App?
  let contentState: ReleaseNotesDetailContentState
  var updating: any AppUpdating = AppUpdateService.shared
  var overview = DetailOverview.chooseApp
  var history = UpdateHistoryStore.shared

  init(
    app: App?, contentState: ReleaseNotesDetailContentState,
    updating: any AppUpdating = AppUpdateService.shared,
    overview: DetailOverview = .chooseApp, history: UpdateHistoryStore = .shared
  ) {
    self.app = app
    self.contentState = contentState
    self.updating = updating
    self.overview = overview
    self.history = history
  }

  var body: some View {
    VStack(spacing: 0) {
      if let app {
        ReleaseNotesHeaderView(app: app, updating: updating)
        ObservedUpdatePresentation(app: app, updating: updating) { presentation in
          UpdateSummaryView(app: app, presentation: presentation, updating: updating)
        }
        .id(ObjectIdentifier(app))
        Divider()
      }
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var content: some View {
    ZStack {
      ReleaseNotesWebView(text: displayedText)
        .opacity(displayedText == nil ? 0 : 1)
        .allowsHitTesting(displayedText != nil)
        .accessibilityHidden(displayedText == nil)

      if let app {
        switch contentState {
        case .message:
          // No notes for this version: the facts about the app take their place.
          AppInfoPanel(app: app, lastResult: history.latestEntry(for: app.fileURL))
        case .loading:
          ProgressView()
            .controlSize(.regular)
            .accessibilityLabel("Loading Release Notes")
        case .text:
          EmptyView()
        }
      } else {
        DetailOverviewView(overview: overview)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var displayedText: ReleaseNotesContent? {
    if case .text(let text) = contentState { return text }
    return nil
  }
}

struct ReleaseNotesHeaderView: View {
  let app: App
  let updating: any AppUpdating
  // App equality compares identifiers and versions; refreshed metadata/actions need object identity.
  private let appIdentity: ObjectIdentifier
  @State private var icon: NSImage?

  init(app: App, updating: any AppUpdating = AppUpdateService.shared) {
    self.app = app
    self.updating = updating
    appIdentity = ObjectIdentifier(app)
  }

  var body: some View {
    HStack(spacing: 5) {
      Group {
        if let icon {
          Image(nsImage: icon)
            .resizable()
            .scaledToFit()
        } else {
          Color.clear
        }
      }
      .frame(width: VisualMetrics.detailIconSize, height: VisualMetrics.detailIconSize)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 0) {
        Text(app.name)
          .font(.system(size: 15, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.tail)
          .offset(y: VisualMetrics.detailTitleVerticalCorrection)
          .frame(height: 19)

        Text(versionLine)
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(Color(nsColor: .secondaryLabelColor))
          .offset(y: VisualMetrics.detailMetadataLineVerticalCorrection)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // The optional date extends below the two-line block without recentering it.
      .overlay(alignment: .topLeading) {
        if let date = app.latestUpdateDate {
          GeometryReader { geometry in
            Text("Released \(date.formatted(.dateTime.year().month(.wide).day()))")
              .font(.system(size: 11))
              .foregroundStyle(Color(nsColor: .secondaryLabelColor))
              .lineLimit(1)
              .offset(y: geometry.size.height + VisualMetrics.detailMetadataLineVerticalCorrection)
          }
        }
      }
      .offset(y: VisualMetrics.detailMetadataVerticalOffset)
      .layoutPriority(1)

      UpdateActionView(app: app, updating: updating)
        .id(appIdentity)

    }
    .padding(.horizontal, VisualMetrics.detailHeaderHorizontalPadding)
    .frame(height: VisualMetrics.detailHeaderHeight)
    .background(.bar)
    .overlay(alignment: .bottom) {
      Divider()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-notes.header")
    .task(id: appIdentity) {
      let loadedIcon = await IconCache.shared.icon(for: app)
      guard !Task.isCancelled else { return }
      icon = loadedIcon
    }
  }

  private var versionLine: String {
    let current = app.localizedVersionInformation?.rawCurrent ?? ""
    if app.availabilityUnknown {
      return "Version \(current) · newer version unknown"
    }
    if app.updateAvailable, let new = app.localizedVersionInformation?.rawNew {
      return "Version \(current) → \(new)"
    }
    return current.isEmpty ? "" : "Version \(current)"
  }
}

/// One plain sentence under the header: what clicking the button does, or what is happening.
private struct UpdateSummaryView: View {
  let app: App
  let presentation: UpdateActionPresentation
  let updating: any AppUpdating

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(tint)
        .frame(width: 16)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 8) {
        Text(sentence)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        if case .failed = presentation,
          let permission = UpdateActionViewModel.missingPermission(for: app, updating: updating)
        {
          Button("Open \(permission.title) Settings") {
            MacApplicationWorkspace.shared.open(permission.settingsURL)
          }
          .controlSize(.small)
          .accessibilityLabel("Open System Settings for \(permission.title)")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(size: 13))
    .padding(.horizontal, VisualMetrics.detailHeaderHorizontalPadding)
    .padding(.vertical, 12)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("detail.summary")
  }

  private var sentence: String {
    switch presentation {
    case .failed(let reason): "The last attempt didn't finish. \(reason)"
    case .waiting(let status), .progress(_, let status, _): "\(status)…"
    case .retryTermination:
      "Waiting for \(app.name) to quit. Save your work in it, then click Retry Quit."
    case .update, .open: app.updateExplanation
    }
  }

  private var symbol: String {
    switch presentation {
    case .failed: return "exclamationmark.triangle.fill"
    case .waiting, .progress, .retryTermination: return "arrow.down.circle"
    case .update, .open:
      if app.isActionable {
        return app.capability.isAutomatic ? "arrow.down.circle.fill" : "arrow.up.forward.app"
      }
      return app.remoteVersion != nil && !app.isUpdaterItself
        ? "checkmark.circle.fill" : "info.circle"
    }
  }

  private var tint: Color {
    switch presentation {
    case .failed: return Color(nsColor: .systemOrange)
    case .update, .open:
      if !app.isActionable, app.remoteVersion != nil, !app.isUpdaterItself {
        return Color(nsColor: .systemGreen)
      }
      return app.isActionable ? .accentColor : .secondary
    case .waiting, .progress, .retryTermination: return .accentColor
    }
  }
}

/// Shown instead of release notes when there are none: versions, route, place and last result.
private struct AppInfoPanel: View {
  let app: App
  let lastResult: UpdateHistoryEntry?

  var body: some View {
    ScrollView {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
        row("Installed", app.localizedVersionInformation?.rawCurrent ?? "Unknown")
        if app.availabilityUnknown {
          row("Available", "Unknown, only \(app.externalUpdaterName ?? "the vendor") knows")
        } else if app.updateAvailable, let new = app.localizedVersionInformation?.rawNew {
          row("Available", new)
        }
        row("Updates via", app.isUpdaterItself ? "Not yet available" : app.sourceName)
        row(
          "Location",
          (app.fileURL.deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath)
        if let lastResult, let summary = Self.describe(lastResult) {
          row("Last update", summary)
        }
      }
      .font(.system(size: 12))
      .padding(.horizontal, VisualMetrics.detailHeaderHorizontalPadding)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("detail.info")
  }

  private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      Text(value)
        .textSelection(.enabled)
        .lineLimit(2)
        .truncationMode(.middle)
    }
    .accessibilityElement(children: .combine)
  }

  static func describe(_ entry: UpdateHistoryEntry) -> String? {
    let when = entry.date.formatted(.dateTime.day().month(.abbreviated).year())
    let what: String
    switch entry.outcome {
    case .updated(let from, let to): what = "Updated \(from) → \(to)"
    case .noChange(let reason): what = "Nothing changed" + (reason.map { ": \($0)" } ?? "")
    case .needsPermission(let kind):
      what = kind == "administrator" ? "Needed your password" : "Blocked by App Management"
    case .needsQuit: what = "Not updated: the app didn't quit"
    case .failed(let reason, _): what = "Failed: \(reason)"
    case .handedOff: what = "Opened \(entry.handOff?.destination ?? "its updater")"
    }
    return "\(what), \(when)"
  }
}

private struct DetailOverviewView: View {
  let overview: DetailOverview

  var body: some View {
    Group {
      switch overview {
      case .lookingForApps:
        ContentUnavailableView {
          ProgressView().controlSize(.large)
        } description: {
          Text("Looking for apps on this Mac…")
        }
      case .checking:
        ContentUnavailableView {
          ProgressView().controlSize(.large)
        } description: {
          Text("Checking for updates. Apps with updates appear on the left as they're found.")
        }
      case .offline:
        ContentUnavailableView(
          "Can't Reach Update Servers", systemImage: "wifi.exclamationmark",
          description: Text("Check your internet connection, then click Check for Updates."))
      case .upToDate(let checked):
        ContentUnavailableView(
          "Everything Is Up to Date", systemImage: "checkmark.circle",
          description: Text(
            checked == 1 ? "Updater checked 1 app." : "Updater checked \(checked) apps."))
      case .chooseApp:
        ContentUnavailableView(
          "No App Selected", systemImage: "square.stack",
          description: Text("Select an app to see what Update will do."))
      }
    }
    .accessibilityIdentifier("detail.overview")
  }
}
