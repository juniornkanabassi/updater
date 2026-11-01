//
//  ReleaseNotesProviderTest.swift
//  Latest Tests
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import CryptoKit
import XCTest

@testable import Latest

final class ReleaseNotesProviderTest: XCTestCase {
  @MainActor
  func testCancelledWebExtractionCannotPublishOlderAcceptedContent() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).html")
    defer { try? FileManager.default.removeItem(at: file) }
    try """
    <html><body><p id="notes">Original notes.</p><script>
    setTimeout(function() { document.getElementById('notes').textContent = 'Replacement notes.'; }, 800);
    </script></body></html>
    """.write(to: file, atomically: true, encoding: .utf8)
    let gate = WebContentAcceptanceGate()
    let completed = expectation(description: "Latest HTML completed")
    var contents = [String]()
    let loader = WebContentLoader()
    defer { loader.cancel() }
    loader.load(from: file, acceptsContent: { await gate.accept($0) }) { result in
      switch result {
      case .success(let html): contents.append(html)
      case .failure(let error): XCTFail("Local page failed: \(error)")
      }
      completed.fulfill()
    }
    await fulfillment(of: [gate.originalRead, gate.replacementRead], timeout: 4)
    await gate.resumeOriginal()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(
      contents.isEmpty, "An extraction cancelled by a newer mutation must not finish the load")
    await gate.resumeReplacement()
    await fulfillment(of: [completed], timeout: 2)
    XCTAssertEqual(contents.count, 1)
    XCTAssertTrue(contents.first?.contains(">Replacement notes.</p>") == true)
  }

  @MainActor
  func testWebLoaderReleasesItsOwnerDuringAnActiveLoad() {
    var loader: WebContentLoader? = WebContentLoader()
    weak let weakLoader = loader
    loader?.load(from: URL(fileURLWithPath: "/missing-\(UUID()).html")) { _ in }
    loader = nil
    XCTAssertNil(weakLoader)
  }

  @MainActor
  func testWebLoaderFailureFinishesOnceAndReleasesResources() async throws {
    var loader: WebContentLoader? = WebContentLoader()
    weak let weakLoader = loader
    let completed = expectation(description: "Missing page failed")
    var completions = 0
    loader?.load(from: URL(fileURLWithPath: "/missing-\(UUID()).html")) { result in
      if case .success = result { XCTFail("A missing file must fail") }
      completions += 1
      completed.fulfill()
    }
    await fulfillment(of: [completed], timeout: 3)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(completions, 1)
    loader = nil
    XCTAssertNil(weakLoader)
  }

  @MainActor
  func testFailedUpdateCheckStillLoadsCachedVendorNotes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ReleaseNotesPersistentCache(directoryURL: directory)
    let bundle = App.Bundle(
      version: Version(versionNumber: "1.14.4", buildNumber: nil),
      name: "Obsidian", bundleIdentifier: "md.obsidian",
      fileURL: URL(fileURLWithPath: "/Applications/Obsidian.app"), source: .none)
    let app = App(
      bundle: bundle, update: .failure(LatestError.updateInfoUnavailable), isIgnored: false)
    let notes = ResolvedReleaseNotes(
      content: ReleaseNotesContent(string: "Fixed missing files in the vault explorer."),
      quality: .genuine, provenance: .changelog)
    await cache.store(
      ReleaseNotesPersistentCache.payload(from: notes),
      forKey: ReleaseNotesCacheKey(app: app).stableIdentifier)
    let result = try await releaseNotes(
      for: app, provider: ReleaseNotesProvider(persistentCache: cache))
    XCTAssertEqual(result.string, notes.content.string)
  }

  @MainActor
  func testInvalidOrFallbackDiskCacheDoesNotBlockHealthyPrimaryNotes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ReleaseNotesPersistentCache(directoryURL: directory)
    let bundle = App.Bundle(
      version: Version(versionNumber: "1", buildNumber: nil), name: "Cache Recovery",
      bundleIdentifier: "test.cache-recovery", fileURL: directory.appendingPathComponent("App.app"),
      source: .sparkle)
    let app = App(
      bundle: bundle,
      update: .success(
        App.Update(
          app: bundle, remoteVersion: Version(versionNumber: "2", buildNumber: nil),
          minimumOSVersion: nil, source: .sparkle, date: nil,
          releaseNotes: .html(string: "Fixed missing files in the project explorer."),
          updateAction: .builtIn { _ in })), isIgnored: false)
    for (text, quality) in [
      (" \n\t", ReleaseNotesQuality.genuine), ("Temporary fallback", .degraded),
      ("Package metadata", .genericMetadata),
    ] {
      await cache.store(
        ReleaseNotesPersistentCache.payload(
          from: ResolvedReleaseNotes(
            content: ReleaseNotesContent(string: text), quality: quality,
            provenance: .bundledFallback)),
        forKey: ReleaseNotesCacheKey(app: app).stableIdentifier)
      let provider = ReleaseNotesProvider(persistentCache: cache)
      let result = try await releaseNotes(for: app, provider: provider)
      XCTAssertTrue(result.string.contains("Fixed missing files"))
      let repeated = try await releaseNotes(for: app, provider: provider)
      XCTAssertEqual(repeated.string, result.string)
    }
  }

  @MainActor
  func testGitHubSelectedReleaseKeepsBodyBeforeVersionedDownloadLink() async throws {
    let html = """
      <p>BetterDisplay 5 brings expanded display arrangement and advanced image controls.</p>
      <h2>Highlights</h2><ul><li>Improved brightness syncing after wake.</li></ul>
      <p><a href="https://github.com/waydabber/BetterDisplay/releases/download/v5.0.5/BetterDisplay-v5.0.5.dmg">Download for macOS</a></p>
      """
    let result = await ReleaseNotesMarkup.githubAttributedStringByPreparingOffMain(
      from: html, title: nil,
      baseURL: URL(string: "https://github.com/waydabber/BetterDisplay/releases/tag/v5.0.5")!,
      relevantVersion: "5.0.5")
    let text = try XCTUnwrap(result).get().string
    XCTAssertTrue(text.contains("expanded display arrangement"))
    XCTAssertTrue(text.contains("Improved brightness syncing"))
  }

  func testInternalFetchErrorsProduceReadableReleaseNoteMessages() {
    let expected = ReleaseNotesMessage(error: LatestError.releaseNotesUnavailable)
    for error in [FetchHTMLError.unusableText, .fetchFailed] {
      XCTAssertEqual(ReleaseNotesMessage(error: error), expected)
    }
  }

  @MainActor
  func testGitHubMarkdownOmitsHTMLDownloadButtonsOutsideCodeFences() async throws {
    let button =
      #"<a href="https://example.com/BetterDisplay-v5.0.6.dmg"><img src="https://example.com/download.png" width="175" alt="Download for macOS"/></a>"#
    let markdown = """
      # BetterDisplay 5.0.6
      - Fixed brightness syncing after wake.
      - Improved display arrangement reliability.

      ```html
      \(button)
      ```

      \(button)
      """
    let result = await ReleaseNotesMarkup.githubAttributedStringByPreparingOffMain(
      from: markdown, title: nil,
      baseURL: URL(string: "https://github.com/waydabber/BetterDisplay/releases/tag/v5.0.6"),
      relevantVersion: "5.0.6")
    let text = try XCTUnwrap(result).get().string
    XCTAssertTrue(text.contains("BetterDisplay 5.0.6"))
    XCTAssertTrue(text.contains("Fixed brightness syncing after wake"))
    XCTAssertTrue(text.contains("Improved display arrangement reliability"))
    XCTAssertEqual(
      text.components(separatedBy: button).count - 1, 1,
      "Keep the literal code example, but omit the image-only footer")
  }

  @MainActor
  func testLatestDevHasVersionMatchedOfflineNotesWithoutAnUpdater() async throws {
    func app(identifier: String, version: String) -> App {
      let bundle = App.Bundle(
        version: Version(versionNumber: version, buildNumber: nil),
        name: "Latest Dev", bundleIdentifier: identifier,
        fileURL: URL(fileURLWithPath: "/Applications/Latest Dev.app"),
        source: .none, modificationDate: .distantPast)
      return App(
        bundle: bundle, update: .failure(LatestError.releaseNotesUnavailable), isIgnored: false)
    }
    let installed = app(identifier: "com.max-langer.Latest.dev", version: "0.59")
    let notes = try await releaseNotes(for: installed, provider: ReleaseNotesProvider())
    XCTAssertTrue(notes.string.contains("Latest Dev 0.59"))
    XCTAssertTrue(notes.string.contains("release-note margins"))
    XCTAssertFalse(installed.supported)
    XCTAssertNil(
      ReleaseNotesProvider.bundledReleaseNotes(
        for: app(identifier: "com.max-langer.Latest.dev", version: "0.57")))
    XCTAssertNil(
      ReleaseNotesProvider.bundledReleaseNotes(
        for: app(identifier: "com.max-langer.Latest", version: "0.59")))
  }

  func testReleaseNotesProviderBuildsGitHubWebURLFromAPIURL() throws {
    let apiURL = URL(string: "https://api.github.com/repos/usebruno/bruno/releases/tags/v3.4.2")!
    let webURL = try XCTUnwrap(ReleaseNotesProvider.githubReleaseWebURL(fromAPIURL: apiURL))

    XCTAssertEqual(webURL.absoluteString, "https://github.com/usebruno/bruno/releases/tag/v3.4.2")
  }

  func testReleaseNotesProviderExtractsGitHubReleaseBodyHTML() throws {
    let html = """
      <main>
      \t<div data-test-selector="body-content" class="markdown-body tmp-my-3">
      \t\t<ul>
      \t\t\t<li>Fix possible crash in OpenGL init.</li>
      \t\t\t<li>Fix display of rich messages without text.</li>
      \t\t</ul>
      \t\t<div><p>Nested note stays in the release body.</p></div>
      \t</div>
      \t<div class="Box-footer">Assets 11</div>
      </main>
      """

    let body = try XCTUnwrap(ReleaseNotesProvider.githubReleaseBodyHTML(fromHTML: html))
    let string = try ReleaseNotesMarkup.attributedString(
      from: body,
      baseURL: URL(string: "https://github.com/telegramdesktop/tdesktop/releases/tag/v6.9.2")!,
      relevantVersion: "6.9.2"
    ).get()

    XCTAssertTrue(string.string.contains("Fix possible crash in OpenGL init."))
    XCTAssertTrue(string.string.contains("Nested note stays in the release body."))
    XCTAssertFalse(string.string.contains("Assets 11"))
  }

  func testReleaseNotesProviderExtractsLinkedNotesFromGitHubReleaseBody() throws {
    let html = """
      <div data-test-selector="body-content" class="markdown-body tmp-my-3">
      \t<p><a href="https://obsidian.md/changelog/2026-03-23-desktop-v1.12.7/">https://obsidian.md/changelog/2026-03-23-desktop-v1.12.7/</a></p>
      </div>
      """

    let body = try XCTUnwrap(ReleaseNotesProvider.githubReleaseBodyHTML(fromHTML: html))
    let url = try XCTUnwrap(
      ReleaseNotesMarkup.firstReleaseNotesURL(
        in: body,
        baseURL: URL(
          string: "https://github.com/obsidianmd/obsidian-releases/releases/tag/v1.12.7")!))

    XCTAssertEqual(url.absoluteString, "https://obsidian.md/changelog/2026-03-23-desktop-v1.12.7/")
    XCTAssertThrowsError(
      try ReleaseNotesMarkup.attributedString(from: body, baseURL: nil, relevantVersion: "1.12.7")
        .get())
  }
  @MainActor
  func testReleaseNotesProviderInvalidatesCacheWhenReleaseNoteSourceChanges() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = ReleaseNotesProvider(
      persistentCache: ReleaseNotesPersistentCache(directoryURL: directory))
    let oldApp = makeReleaseNotesApp(html: "<p>Old release notes with bug fixes.</p>")
    let refreshedApp = makeReleaseNotesApp(html: "<p>Fresh release notes with improvements.</p>")

    let oldNotes = try await releaseNotes(for: oldApp, provider: provider)
    let refreshedNotes = try await releaseNotes(for: refreshedApp, provider: provider)

    XCTAssertTrue(oldNotes.string.contains("Old release notes"))
    XCTAssertTrue(refreshedNotes.string.contains("Fresh release notes"))
    XCTAssertFalse(refreshedNotes.string.contains("Old release notes"))
  }

  @MainActor
  func testReleaseNotesProviderRejectsDownloadLikeReleaseNotesURL() async {
    let provider = ReleaseNotesProvider()
    let app = makeReleaseNotesApp(
      releaseNotes: .url(url: URL(string: "https://example.com/Thunder.dmg")!))
    let expectation = expectation(description: "release notes completion")
    var capturedError: Error?

    provider.releaseNotes(for: app) { result in
      if case .failure(let error) = result {
        capturedError = error
      }
      expectation.fulfill()
    }

    await fulfillment(of: [expectation], timeout: 1)

    guard let error = capturedError as? LatestError,
      case .releaseNotesUnavailable = error
    else {
      return XCTFail(
        "Expected downloadable release note URLs to be rejected before the web loader.")
    }
  }

  @MainActor
  func testDetailRefreshesChangedNotesButDoesNotReloadForPresentationChanges() {
    let provider = DeferredNotesProvider()
    let model = ReleaseNotesDetailViewModel(releaseNotesProvider: provider)
    let first = makeReleaseNotesApp(html: "<p>Original content.</p>")
    let changed = makeReleaseNotesApp(html: "<p>Changed content.</p>")
    model.display(first)
    let ignored = first.with(ignoredState: true)
    model.display(ignored)
    XCTAssertTrue(model.app === ignored)
    XCTAssertEqual(provider.completions.count, 1)
    model.display(changed)
    XCTAssertEqual(provider.completions.count, 2)
    provider.completions[1](.success(ReleaseNotesContent(string: "New")))
    provider.completions[0](.success(ReleaseNotesContent(string: "Old")))
    guard case .text(let text) = model.contentState else { return XCTFail("Expected text") }
    XCTAssertEqual(text.string, "New")
    model.display(nil)
    provider.completions[1](.success(ReleaseNotesContent(string: "Late")))
    guard case .message = model.contentState else { return XCTFail("Selection was cleared") }
  }

  @MainActor
  func testProviderDiskHitDoesNotRewriteOrRenewPayload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ReleaseNotesPersistentCache(directoryURL: directory)
    let app = makeReleaseNotesApp(html: "<p>Unused source.</p>")
    let key = ReleaseNotesCacheKey(app: app).stableIdentifier
    let resolved = ResolvedReleaseNotes(
      content: ReleaseNotesContent(string: "Cached notes"),
      quality: .genuine, provenance: .changelog)
    let encoded = ReleaseNotesPersistentCache.payload(from: resolved)
    let storedAt = Date(timeIntervalSinceNow: -3600)
    let payload = ReleaseNotesPersistentPayload(
      richTextData: encoded.richTextData, semanticContent: encoded.semanticContent,
      qualityRawValue: encoded.qualityRawValue, provenanceRawValue: encoded.provenanceRawValue,
      storedAt: storedAt)
    await cache.store(payload, forKey: key)
    let file = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      ).first)
    let before = try Data(contentsOf: file)
    let modificationDate = try file.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    let provider = ReleaseNotesProvider(persistentCache: cache)
    let notes = try await releaseNotes(for: app, provider: provider)
    XCTAssertEqual(notes.string, "Cached notes")
    // Drain main-actor tasks before inspecting the serial cache actor.
    await Task.yield()
    let loaded = await cache.payload(forKey: key)
    XCTAssertEqual(loaded?.storedAt, storedAt)
    XCTAssertEqual(try Data(contentsOf: file), before)
    XCTAssertEqual(
      try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
      modificationDate)
  }

  @MainActor
  private func releaseNotes(for app: App, provider: ReleaseNotesProvider) async throws
    -> ReleaseNotesContent
  {
    var result: ReleaseNotesProvider.ReleaseNotes?
    let expectation = expectation(description: "release notes completion")
    provider.releaseNotes(for: app) { notes in
      result = notes
      expectation.fulfill()
    }
    // HTML-to-attributed-string conversion can briefly exceed one second on a
    // busy debug XCTest host even though it runs fully off the network.
    await fulfillment(of: [expectation], timeout: 3)

    return try XCTUnwrap(result).get()
  }

  private func makeReleaseNotesApp(html: String) -> App {
    makeReleaseNotesApp(releaseNotes: .html(string: html))
  }

  private func makeReleaseNotesApp(releaseNotes: App.Update.ReleaseNotes) -> App {
    let bundle = App.Bundle(
      version: Version(versionNumber: "1.4.2", buildNumber: nil),
      name: "Zed",
      bundleIdentifier: "dev.zed.Zed",
      fileURL: URL(fileURLWithPath: "/Applications/Zed.app", isDirectory: true),
      source: .homebrew
    )
    let update = App.Update(
      app: bundle,
      remoteVersion: Version(versionNumber: "1.4.4", buildNumber: nil),
      minimumOSVersion: nil,
      source: .homebrew,
      date: nil,
      releaseNotes: releaseNotes,
      updateAction: .external(label: "Zed") { _ in }
    )

    return App(bundle: bundle, update: .success(update), isIgnored: false)
  }

}

@MainActor
private final class DeferredNotesProvider: ReleaseNotesProviding {
  var completions = [ReleaseNotesProvider.Completion]()
  func releaseNotes(for app: App, with completion: @escaping ReleaseNotesProvider.Completion) {
    completions.append(completion)
  }
}

private actor WebContentAcceptanceGate {
  nonisolated let originalRead = XCTestExpectation(
    description: "Original snapshot waiting for acceptance")
  nonisolated let replacementRead = XCTestExpectation(
    description: "Replacement snapshot waiting for acceptance")
  private var original: CheckedContinuation<Bool, Never>?
  private var replacement: CheckedContinuation<Bool, Never>?

  func accept(_ html: String) async -> Bool {
    await withCheckedContinuation { continuation in
      if html.contains(">Original notes.</p>") {
        original = continuation
        originalRead.fulfill()
      } else {
        replacement = continuation
        replacementRead.fulfill()
      }
    }
  }

  func resumeOriginal() {
    original?.resume(returning: true)
    original = nil
  }
  func resumeReplacement() {
    replacement?.resume(returning: true)
    replacement = nil
  }
}
