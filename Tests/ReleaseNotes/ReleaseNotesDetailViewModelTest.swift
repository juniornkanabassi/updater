// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import XCTest

@testable import Latest

final class ReleaseNotesDetailViewModelTest: XCTestCase {
  @MainActor
  func testLateCatalogRefreshRetriesSelectedDetailsWithoutAnotherListPublication() async throws {
    let provider = ReleaseNotesProviderProbe()
    let detail = ReleaseNotesDetailViewModel(releaseNotesProvider: provider)
    let app = makeTestApp(name: "Late catalog", version: "1", remoteVersion: "2")
    let settings = try isolatedAppListSettings(for: self)
    let list = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: [app], filterQuery: nil, settings: settings),
      settings: settings)
    list.select(app)
    detail.display(app)
    provider.completeRequest(at: 0, with: .failure(LatestError.releaseNotesUnavailable))
    let host = NSHostingView(
      rootView: ReleaseNotesDetailView(
        updatesViewModel: list, detailViewModel: detail))
    host.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    // Finish initial view/layout work before catalog activation. No app-list or
    // selection events will occur after this point.
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(provider.requests.count, 1)
    let snapshotRevision = list.snapshotRevision
    let catalogURL = try XCTUnwrap(
      Bundle.main.url(forResource: "ReleaseNotesSources", withExtension: "json"))
    let client = SignedReleaseNotesCatalogClient(
      configuration: .disabled, bundledCatalogData: try Data(contentsOf: catalogURL))
    let oldRevision = ReleaseNotesSourceCatalog.revision
    let newRevision = await ReleaseNotesSourceCatalog.refresh(client: client)
    XCTAssertGreaterThan(newRevision, oldRevision)
    let deadline = ContinuousClock.now + .seconds(2)
    while provider.requests.count < 2 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(
      provider.requests.count, 2,
      "Late catalog activation must retry the selected app without another list event")
    guard provider.requests.count == 2 else { return }
    XCTAssertTrue(list.selectedApp === app)
    XCTAssertTrue(provider.requests[1].app === app)
    XCTAssertEqual(list.snapshotRevision, snapshotRevision)
    provider.completeRequest(
      at: 1, with: .success(ReleaseNotesContent(string: "Updated catalog notes")))
    guard case .text(let content) = detail.contentState else {
      return XCTFail("Expected refreshed release notes")
    }
    XCTAssertEqual(content.string, "Updated catalog notes")
    _ = host  // Retain the subscribed production view for the entire refresh.
  }

  @MainActor
  func testRapidSelectionRequestsNotesOnlyForTheSettledApp() async throws {
    let provider = ReleaseNotesProviderProbe()
    let viewModel = ReleaseNotesDetailViewModel(releaseNotesProvider: provider)
    let first = makeTestApp(name: "Discord", version: "1", remoteVersion: "2")
    let second = makeTestApp(name: "Cursor", version: "3", remoteVersion: "4")

    viewModel.display(first, waitForSelectionToSettle: true)
    // The user's held keys repeat about every 83ms. Back-to-back calls hid
    // notes work that started between real repeat events.
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertTrue(provider.requests.isEmpty, "Held navigation must not fetch each passing row")
    viewModel.display(second, waitForSelectionToSettle: true)
    XCTAssertTrue(viewModel.app === second, "The header must follow selection immediately")
    XCTAssertTrue(provider.requests.isEmpty, "Passing a row must not start expensive notes work")
    let deadline = ContinuousClock.now + .seconds(1)
    while provider.requests.isEmpty && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(provider.requests.count, 1)
    XCTAssertTrue(provider.requests.last?.app === second)

    viewModel.display(first, waitForSelectionToSettle: true)
    viewModel.display(nil)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(provider.requests.count, 1, "Clearing selection must cancel queued notes work")
    guard case .message(let message) = viewModel.contentState else {
      return XCTFail("Expected no-selection content")
    }
    XCTAssertEqual(message, .noSelection)
  }

  @MainActor
  func testKeyboardSelectionCancelsStaleNotesAndRetriesWhenReturning() async throws {
    let provider = ReleaseNotesProviderProbe()
    let model = ReleaseNotesDetailViewModel(releaseNotesProvider: provider)
    let first = makeTestApp(name: "First", version: "1", remoteVersion: "2")
    let second = makeTestApp(name: "Second", version: "3", remoteVersion: "4")
    model.display(first)
    model.display(second, waitForSelectionToSettle: true)
    provider.completeRequest(at: 0, with: .success(ReleaseNotesContent(string: "Stale notes")))
    guard case .message(.noSelection) = model.contentState else {
      return XCTFail("A pending keyboard selection must reject the previous request's result")
    }
    model.display(first, waitForSelectionToSettle: true)
    let deadline = ContinuousClock.now + .seconds(1)
    while provider.requests.count < 2 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(provider.requests.count, 2, "Returning must retry the cancelled request")
    guard provider.requests.count == 2 else { return }
    XCTAssertTrue(provider.requests[1].app === first)
    let notes = ReleaseNotesContent(string: "Current notes")
    provider.completeRequest(at: 1, with: .success(notes))
    let refreshed = makeTestApp(name: "First", version: "1", remoteVersion: "2")
    model.display(refreshed)
    XCTAssertTrue(model.app === refreshed, "Equivalent notes must not suppress refreshed metadata")
    XCTAssertEqual(provider.requests.count, 2, "A completed result with the same key can be reused")
    guard case .text(let displayed) = model.contentState else {
      return XCTFail("Expected current notes")
    }
    XCTAssertTrue(displayed === notes)
  }

  @MainActor
  func testDetailViewModelOwnsLoadingSuccessEmptyErrorAndStaleRequestStates() async throws {
    let provider = ReleaseNotesProviderProbe()
    let viewModel = ReleaseNotesDetailViewModel(releaseNotesProvider: provider)
    let firstApp = makeTestApp(name: "Discord", version: "1", remoteVersion: "2")
    let secondApp = makeTestApp(name: "Cursor", version: "3", remoteVersion: "4")

    viewModel.display(firstApp)
    XCTAssertEqual(provider.requests.count, 1)
    try await Task.sleep(for: .milliseconds(230))
    guard case .loading = viewModel.contentState else {
      return XCTFail("Expected delayed loading state.")
    }

    let firstText = ReleaseNotesContent(string: "First release notes")
    provider.completeRequest(at: 0, with: .success(firstText))
    guard case .text(let displayedText) = viewModel.contentState else {
      return XCTFail("Expected release notes text.")
    }
    XCTAssertEqual(displayedText.string, firstText.string)

    viewModel.display(secondApp)
    XCTAssertEqual(provider.requests.count, 2)
    provider.completeRequest(at: 0, with: .success(ReleaseNotesContent(string: "Stale text")))
    guard case .text(let textAfterStaleCompletion) = viewModel.contentState else {
      return XCTFail("A stale request must not replace the current detail state.")
    }
    XCTAssertEqual(textAfterStaleCompletion.string, firstText.string)

    provider.completeRequest(at: 1, with: .success(ReleaseNotesContent(string: "  \n")))
    guard case .message(let emptyMessage) = viewModel.contentState else {
      return XCTFail("Expected an empty release note response to become an unavailable message.")
    }
    XCTAssertEqual(emptyMessage.description, LatestError.releaseNotesUnavailable.failureReason)

    let thirdApp = makeTestApp(name: "Zed", version: "5", remoteVersion: "6")
    viewModel.display(thirdApp)
    provider.completeRequest(at: 2, with: .failure(LatestError.updateInfoUnavailable))
    guard case .message(let errorMessage) = viewModel.contentState else {
      return XCTFail("Expected provider failures to become detail messages.")
    }
    XCTAssertEqual(errorMessage.title, LatestError.updateInfoUnavailable.localizedDescription)
    XCTAssertEqual(errorMessage.description, LatestError.updateInfoUnavailable.failureReason)

    viewModel.display(nil)
    guard case .message(let noSelectionMessage) = viewModel.contentState else {
      return XCTFail("Expected the no-selection message.")
    }
    XCTAssertEqual(noSelectionMessage, .noSelection)
  }

  @MainActor
  func testUpdateCheckFailureUsesCompactReleaseNotesEmptyState() {
    let bundle = Latest.App.Bundle(
      version: Version(versionNumber: "26.707.51957", buildNumber: nil),
      name: "ChatGPT",
      bundleIdentifier: "com.openai.codex",
      fileURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
      source: .sparkle
    )
    let app = Latest.App(
      bundle: bundle, update: .failure(LatestError.updateInfoUnavailable), isIgnored: false)
    let viewModel = ReleaseNotesDetailViewModel()

    viewModel.display(app)

    guard case .message(let message) = viewModel.contentState else {
      return XCTFail(
        "Expected the provider to map update-check failures to a release-notes message.")
    }
    XCTAssertEqual(message.title, NSLocalizedString("ReleaseNotesUnavailableError", comment: ""))
    XCTAssertEqual(
      message.description,
      NSLocalizedString("ReleaseNotesUnavailableErrorFailureReason", comment: ""))
    XCTAssertNotEqual(
      message.description, NSLocalizedString("UpdateInfoUnavailableErrorFailureReason", comment: "")
    )
  }
}

@MainActor
private final class ReleaseNotesProviderProbe: ReleaseNotesProviding {
  private(set) var requests: [(app: Latest.App, completion: ReleaseNotesProvider.Completion)] = []

  func releaseNotes(
    for app: Latest.App,
    with completion: @escaping ReleaseNotesProvider.Completion
  ) {
    requests.append((app, completion))
  }

  func completeRequest(at index: Int, with result: ReleaseNotesProvider.ReleaseNotes) {
    requests[index].completion(result)
  }
}
