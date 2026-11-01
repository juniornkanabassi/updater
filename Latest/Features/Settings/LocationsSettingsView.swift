//
//  LocationsSettingsView.swift
//  Latest
//
//  Created by ertyoii on 03.06.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import SwiftUI
import UniformTypeIdentifiers

struct LocationsSettingsView: View {
  @ObservedObject var viewModel: SettingsViewModel
  @State private var showsDirectoryImporter = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Check apps from these folders.")
        .foregroundStyle(.secondary)

      DirectoryLocationsTable(
        urls: viewModel.directoryURLs,
        selection: $viewModel.selectedDirectory
      )
      .frame(height: min(200, max(96, CGFloat(viewModel.directoryURLs.count) * 34 + 12)))
      .clipShape(.rect(cornerRadius: 8))

      ControlGroup {
        Button {
          showsDirectoryImporter = true
        } label: {
          Image(systemName: "plus")
        }
        .accessibilityLabel("Add Location")

        Button {
          viewModel.removeSelectedDirectory()
        } label: {
          Image(systemName: "minus")
        }
        .accessibilityLabel("Remove Location")
        .disabled(!viewModel.canRemove(viewModel.selectedDirectory))
      }
      .controlSize(.small)
      .fixedSize()
    }
    .padding(20)
    .fileImporter(
      isPresented: $showsDirectoryImporter,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: true
    ) { result in
      guard case .success(let urls) = result else { return }
      viewModel.addDirectories(urls)
    }
  }
}

struct DirectoryLocationDetails: Equatable, Sendable {
  let isReachable: Bool
  let appCount: Int
}

enum DirectoryLocationPresentation {
  static func accessibilityLabel(for url: URL, details: DirectoryLocationDetails?) -> String {
    guard let details else {
      return "\(url.relativePath), counting applications"
    }
    if !details.isReachable {
      return "\(url.relativePath), unavailable, \(details.appCount) applications"
    }
    return "\(url.relativePath), \(details.appCount) applications"
  }
}

typealias DirectoryLocationDetailsLoader = @Sendable (URL) async -> DirectoryLocationDetails

struct DirectoryLocationsTable: View {
  private struct Location: Identifiable {
    let url: URL
    var id: URL { url }
  }

  let urls: [URL]
  @Binding var selection: URL?
  let loadDetails: DirectoryLocationDetailsLoader

  init(
    urls: [URL],
    selection: Binding<URL?>,
    loadDetails: @escaping DirectoryLocationDetailsLoader = DirectoryAppCountCache.shared.details
  ) {
    self.urls = urls
    _selection = selection
    self.loadDetails = loadDetails
  }

  var body: some View {
    Table(urls.map(Location.init), selection: $selection) {
      TableColumn("Location") { location in
        DirectoryLocationRow(url: location.url, loadDetails: loadDetails)
      }
    }
    .tableColumnHeaders(.hidden)
    .tableStyle(.bordered)
    .alternatingRowBackgrounds(.enabled)
    .accessibilityIdentifier("settings.locations.table")
  }
}

private struct DirectoryLocationRow: View {
  private enum LoadState: Equatable {
    case loading
    case loaded(DirectoryLocationDetails)
  }

  let url: URL
  let loadDetails: DirectoryLocationDetailsLoader
  @State private var loadState: LoadState = .loading

  var body: some View {
    HStack(spacing: 6) {
      locationIcon
        .frame(width: 16, height: 16)

      Text(url.relativePath)
        .foregroundStyle(isReachable == false ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 4)

      switch loadState {
      case .loading:
        ProgressView()
          .controlSize(.small)
          .frame(width: 16, height: 16)
          .accessibilityLabel("Counting applications")
      case .loaded(let details):
        Text(details.appCount, format: .number)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
    .frame(maxWidth: .infinity, minHeight: 24)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .task(id: url) {
      loadState = .loading
      let details = await loadDetails(url)
      guard !Task.isCancelled else { return }
      loadState = .loaded(details)
    }
  }

  @ViewBuilder
  private var locationIcon: some View {
    if isReachable == false {
      Image(systemName: "exclamationmark.triangle")
        .resizable()
        .scaledToFit()
        .foregroundStyle(.secondary)
    } else {
      Image(systemName: "folder.fill")
        .resizable()
        .scaledToFit()
        .foregroundStyle(.tint)
    }
  }

  private var isReachable: Bool? {
    guard case .loaded(let details) = loadState else { return nil }
    return details.isReachable
  }

  private var accessibilityLabel: String {
    switch loadState {
    case .loading:
      return DirectoryLocationPresentation.accessibilityLabel(for: url, details: nil)
    case .loaded(let details):
      return DirectoryLocationPresentation.accessibilityLabel(for: url, details: details)
    }
  }
}

actor DirectoryAppCountCache {
  static let shared = DirectoryAppCountCache()

  private struct Entry {
    let details: DirectoryLocationDetails
    let expiresAt: Date
    var lastAccessedAt: Date
  }

  private var entries = [URL: Entry]()
  private var inFlightTasks = [URL: Task<DirectoryLocationDetails, Never>]()
  private let lifetime: TimeInterval = 60
  private let maximumEntryCount = 64

  func details(for url: URL) async -> DirectoryLocationDetails {
    let key = url.standardizedFileURL
    let now = Date()
    if var entry = entries[key], entry.expiresAt > now {
      entry.lastAccessedAt = now
      entries[key] = entry
      return entry.details
    }
    entries[key] = nil

    if let task = inFlightTasks[key] {
      return await task.value
    }

    let task = Task.detached(priority: .utility) {
      let isReachable = (try? key.checkResourceIsReachable()) == true
      let count: Int
      if let cachedCount = BundleCollector.cachedBundleCount(at: key) {
        count = cachedCount
      } else if isReachable {
        count = BundleCollector.collectBundles(at: key).count
      } else {
        count = 0
      }
      return DirectoryLocationDetails(isReachable: isReachable, appCount: count)
    }
    inFlightTasks[key] = task

    let details = await task.value
    let storedAt = Date()
    entries[key] = Entry(
      details: details,
      expiresAt: storedAt.addingTimeInterval(lifetime),
      lastAccessedAt: storedAt
    )
    while entries.count > maximumEntryCount {
      guard
        let leastRecentlyUsedKey = entries.min(by: {
          $0.value.lastAccessedAt < $1.value.lastAccessedAt
        })?.key
      else { break }
      entries[leastRecentlyUsedKey] = nil
    }
    inFlightTasks[key] = nil
    return details
  }
}
