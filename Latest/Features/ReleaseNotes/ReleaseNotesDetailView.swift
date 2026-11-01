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
  let showsSupportStatus: Bool

  init(
    updatesViewModel: UpdatesListViewModel,
    detailViewModel: ReleaseNotesDetailViewModel = ReleaseNotesDetailViewModel(),
    showsSupportStatus: Bool = true
  ) {
    self.updatesViewModel = updatesViewModel
    self.showsSupportStatus = showsSupportStatus
    _detailViewModel = StateObject(wrappedValue: detailViewModel)
  }

  var body: some View {
    ReleaseNotesDetailSurface(
      app: detailViewModel.app,
      contentState: detailViewModel.contentState,
      showsSupportStatus: showsSupportStatus,
      updating: updatesViewModel.updating
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

struct ReleaseNotesDetailSurface: View {
  let app: App?
  let contentState: ReleaseNotesDetailContentState
  var showsSupportStatus = true
  var updating: any AppUpdating = AppUpdateService.shared
  // SwiftUI compares stored view inputs using App equality. Object identity
  // keeps equal-version source/action refreshes from skipping this surface.
  private let appIdentity: ObjectIdentifier?

  init(
    app: App?, contentState: ReleaseNotesDetailContentState, showsSupportStatus: Bool = true,
    updating: any AppUpdating = AppUpdateService.shared
  ) {
    self.app = app
    self.contentState = contentState
    self.showsSupportStatus = showsSupportStatus
    self.updating = updating
    appIdentity = app.map(ObjectIdentifier.init)
  }

  var body: some View {
    VStack(spacing: 0) {
      if let app {
        ReleaseNotesHeaderView(
          app: app, showsSupportStatus: showsSupportStatus, updating: updating)

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

      switch contentState {
      case .message(let message):
        ReleaseNotesMessageView(message: message)
      case .loading:
        ProgressView()
          .controlSize(.regular)
          .accessibilityLabel("Loading Release Notes")
      case .text:
        EmptyView()
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
  let showsSupportStatus: Bool
  let updating: any AppUpdating
  // App equality compares identifiers and versions; refreshed metadata/actions need object identity.
  private let appIdentity: ObjectIdentifier
  @State private var icon: NSImage?

  init(
    app: App, showsSupportStatus: Bool = true,
    updating: any AppUpdating = AppUpdateService.shared
  ) {
    self.app = app
    self.showsSupportStatus = showsSupportStatus
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
        appTitle
          .offset(y: VisualMetrics.detailTitleVerticalCorrection)
          .frame(height: 19)

        if let version = app.localizedVersionInformation?.combined(includeNew: app.updateAvailable)
        {
          Text(version)
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .offset(y: VisualMetrics.detailMetadataLineVerticalCorrection)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // The optional date extends below the two-line block without recentering it.
      .overlay(alignment: .topLeading) {
        if let date = app.latestUpdateDate {
          GeometryReader { geometry in
            Text(date, format: .dateTime.year().month(.wide).day())
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

  @ViewBuilder
  private var appTitle: some View {
    if showsSupportStatus {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          appName
            .fixedSize(horizontal: true, vertical: false)
          SupportStatusButton(app: app)
            .id(appIdentity)
        }

        HStack(spacing: 5) {
          appName
          SupportStatusButton(app: app, showsLabel: false)
            .id(appIdentity)
        }
      }
    } else {
      appName
    }
  }

  private var appName: some View {
    Text(app.name)
      .font(.system(size: 13, weight: .semibold))
      .lineLimit(1)
      .truncationMode(.tail)
  }
}

private struct ReleaseNotesMessageView: View {
  let message: ReleaseNotesMessage

  var body: some View {
    VStack(spacing: 8) {
      if let title = message.title, !title.isEmpty {
        Text(title)
          .font(.headline)
      }
      Text(message.description)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: 420)
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("release-notes.message")
  }
}
