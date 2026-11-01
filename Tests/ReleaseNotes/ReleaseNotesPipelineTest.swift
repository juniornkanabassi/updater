//
//  ReleaseNotesPipelineTest.swift
//  Latest Tests
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import CryptoKit
import XCTest

@testable import Latest

final class ReleaseNotesPipelineTest: XCTestCase {

  func testCancelledCacheReaderReturnsBeforeSharedFetchCompletes() async throws {
    for useGitHubCache in [false, true] {
      let htmlCache = ReleaseNotesHTMLCache()
      let gitHubCache = ReleaseNotesGitHubCache()
      let url = URL(string: "https://example.invalid/shared")!
      let started = expectation(description: "Shared loader started")
      let cancelled = expectation(description: "Cancelled reader released")
      let gate = AsyncStream<Void>.makeStream()
      let loader: @Sendable () async throws -> String = {
        started.fulfill()
        for await _ in gate.stream { break }
        return "Shared release notes"
      }
      let reader = Task {
        do {
          if useGitHubCache {
            _ = try await gitHubCache.data(for: url) { Data(try await loader().utf8) }
          } else {
            _ = try await htmlCache.html(for: url, loader: loader)
          }
          XCTFail("Cancelled reader must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        cancelled.fulfill()
      }
      await fulfillment(of: [started], timeout: 2)
      reader.cancel()
      await fulfillment(of: [cancelled], timeout: 2)
      // Keep the shared fetch suspended until cancellation has been observed.
      // A second reader must still receive the result of that same fetch.
      gate.continuation.yield(())
      gate.continuation.finish()
      if useGitHubCache {
        let data = try await gitHubCache.data(for: url) {
          XCTFail("Cancellation must not discard a shared fetch")
          return Data()
        }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "Shared release notes")
      } else {
        let html = try await htmlCache.html(for: url) {
          XCTFail("Cancellation must not discard a shared fetch")
          return ""
        }
        XCTAssertEqual(html, "Shared release notes")
      }
      await reader.value
    }
  }

  func testHTMLCacheDoesNotCacheCancellation() async throws {
    let cancellations: [any Error] = [CancellationError(), URLError(.cancelled)]
    for cancellation in cancellations {
      let cache = ReleaseNotesHTMLCache()
      let url = URL(string: "https://example.com/cancelled")!
      await XCTAssertThrowsErrorAsync(try await cache.html(for: url) { throw cancellation }) {
        XCTAssertTrue($0 is CancellationError || ($0 as? URLError)?.code == .cancelled)
      }
      let recovered = try await cache.html(for: url) { "Recovered release notes" }
      XCTAssertEqual(recovered, "Recovered release notes")
    }
  }

  func testPipelinePreservesSelectedSourceAndRequestedVersion() async throws {
    let context = ReleaseNotesContext(
      appName: "Example", bundleIdentifier: "com.example.App", localVersion: "1.0",
      remoteVersion: "2.0")
    let candidate = ReleaseNotesCandidate(
      markup: """
        # 2.0
        - Fixed crashes when opening large documents and improved editor performance.
        # 1.0
        - Added an older feature that belongs to the previous release.
        """, baseURL: nil, provenance: .changelog)
    let resolved = try await ReleaseNotesPipeline().resolve(candidate, for: context).get()
    XCTAssertEqual(resolved.provenance, .changelog)
    XCTAssertEqual(resolved.quality, .genuine)
    XCTAssertTrue(resolved.content.string.contains("Fixed crashes"))
    XCTAssertFalse(resolved.content.string.contains("older feature"))
  }

  func testHTMLCacheReusesSuccessAndUnusableTextFailure() async throws {
    let cache = ReleaseNotesHTMLCache()
    let url = URL(string: "https://example.com/success")!
    _ = try await cache.html(for: url) { "Cached release notes" }
    let cached = try await cache.html(for: url) {
      XCTFail("A cache hit must not fetch again")
      return "Unexpected replacement"
    }
    XCTAssertEqual(cached, "Cached release notes")

    let unusableURL = URL(string: "https://example.com/unusable")!
    await XCTAssertThrowsErrorAsync(
      try await cache.html(for: unusableURL) { throw FetchHTMLError.unusableText }
    ) { XCTAssertEqual($0 as? FetchHTMLError, .unusableText) }
    await XCTAssertThrowsErrorAsync(
      try await cache.html(for: unusableURL) {
        XCTFail("Unusable responses should retain their negative cache")
        return "Unexpected replacement"
      }
    ) { XCTAssertEqual($0 as? FetchHTMLError, .unusableText) }
  }

  func testPipelineRejectsEmptyContentBeforeRendering() async {
    let context = ReleaseNotesContext(
      appName: "Example", bundleIdentifier: "com.example.App", localVersion: "1", remoteVersion: "2"
    )
    let candidate = ReleaseNotesCandidate(markup: " \n", baseURL: nil, provenance: .changelog)
    let result = await ReleaseNotesPipeline().resolve(candidate, for: context)
    XCTAssertThrowsError(try result.get()) {
      XCTAssertEqual($0 as? ReleaseNotesCandidateRejection, .empty)
    }
  }

  func testCurrentTelegramRegressionSelectsExactDesktopVersion() throws {
    let changelog = """
      7.0.3
      - Fix media viewer freezes on macOS.
      - Improve message rendering performance.
      7.0.2
      - Older unrelated fix.
      """
    let text = try XCTUnwrap(
      ReleaseNotesMarkup.relevantChangelogText(
        fromHTML: changelog,
        version: "7.0.3",
        pageURL: URL(
          string: "https://raw.githubusercontent.com/telegramdesktop/tdesktop/dev/changelog.txt")!,
        allowFirstSectionFallback: false
      ))

    XCTAssertTrue(text.contains("Fix media viewer freezes on macOS"))
    XCTAssertFalse(text.contains("Older unrelated fix"))
  }

  func testCurrentZedRegressionPrefersCompleteRenderedArticleOverTruncatedTransportPayload() throws
  {
    let html = """
      <html><body>
      <nav><a>1.11.4</a><a>1.11.3</a></nav>
      <main><div id="zed-1.11.3"><header><p>1.11.3</p><p>July 16, 2026</p></header><article>
      <p>This week's release includes complete collaboration improvements for shared projects.</p>
      <h2>Features</h2>
      <p>Fixed language server crashes when opening large workspaces.</p></article></div></main>
      <script>self.__next_f.push([1,"{\\\"release\\\":{\\\"version\\\":\\\"1.11.3\\\",\\\"description\\\":\\\"Fixed one truncated item.\\\"}}"])</script>
      </body></html>
      """
    let text = try XCTUnwrap(
      ZedReleaseNotesExtractor.zedReleaseText(
        fromHTML: html,
        version: "1.11.3",
        pageURL: URL(string: "https://zed.dev/releases/stable/1.11.3")!
      ))

    XCTAssertTrue(text.contains("complete collaboration improvements"))
    XCTAssertTrue(text.contains("language server crashes"))
    XCTAssertFalse(text.contains("truncated item"))
  }

  func testCurrentZoomRegressionDropsIOSOnlyRows() throws {
    let html = """
      <html><body>
      <h2>July 15, 2026 version 7.1.0 (83064)</h2>
      <h3>New, enhanced, and changed features</h3>
      <p>New or enhanced feature</p><p>Desktop meeting controls</p>
      <p>Improves meeting controls for desktop participants.</p><p>Windows</p><p>macOS</p><p>Linux</p>
      <p>New or enhanced feature</p><p>Mobile camera effects</p>
      <p>Adds iPhone camera effects.</p><p>iOS</p><p>iOS (Intune)</p>
      <h2>July 8, 2026 version 7.0.9</h2><p>Resolved issue</p><p>Older fix.</p><p>macOS</p>
      </body></html>
      """
    let text = try XCTUnwrap(
      ZoomReleaseNotesExtractor.zoomReleaseText(
        fromHTML: html,
        version: "7.1.0",
        pageURL: URL(
          string: "https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0061222")!
      ))

    XCTAssertTrue(text.contains("Desktop meeting controls"))
    XCTAssertFalse(text.contains("Mobile camera effects"))
    XCTAssertFalse(text.contains("iPhone camera effects"))
    XCTAssertFalse(text.contains("Older fix"))
  }

  func testReleaseNotesCandidateScorerRejectsWrongIdentityVersionPlatformAndSize() {
    let scorer = ReleaseNotesCandidateScorer(maximumMarkupSize: 32)
    let context = ReleaseNotesContext(
      appName: "Zed",
      bundleIdentifier: "dev.zed.Zed",
      localVersion: "1.11.2",
      remoteVersion: "1.11.3"
    )

    XCTAssertThrowsError(
      try scorer.quality(
        of: ReleaseNotesCandidate(
          markup: "Useful fixes for editors.", baseURL: nil, provenance: .changelog,
          declaredAppIdentifiers: ["com.example.Other"]
        ), for: context)
    ) { XCTAssertEqual($0 as? ReleaseNotesCandidateRejection, .wrongApplication) }
    XCTAssertThrowsError(
      try scorer.quality(
        of: ReleaseNotesCandidate(
          markup: "Useful fixes for editors.", baseURL: nil, provenance: .changelog,
          declaredVersion: "1.12.0"
        ), for: context)
    ) { XCTAssertEqual($0 as? ReleaseNotesCandidateRejection, .wrongVersion) }
    XCTAssertThrowsError(
      try scorer.quality(
        of: ReleaseNotesCandidate(
          markup: "Useful fixes for editors.", baseURL: nil, provenance: .changelog,
          declaredPlatforms: ["iOS"]
        ), for: context)
    ) { XCTAssertEqual($0 as? ReleaseNotesCandidateRejection, .wrongPlatform) }
    XCTAssertThrowsError(
      try scorer.quality(
        of: ReleaseNotesCandidate(
          markup: String(repeating: "x", count: 33), baseURL: nil, provenance: .changelog
        ), for: context)
    ) { XCTAssertEqual($0 as? ReleaseNotesCandidateRejection, .oversized) }
  }

  func testGenericHomebrewMetadataHasDistinctQualityAndProvenance() {
    let releaseNotes = App.Update.ReleaseNotes.genericMetadata(
      string: "Example 1.1 is available from Homebrew.")
    XCTAssertEqual(releaseNotes.qualityHint, .genericMetadata)
    XCTAssertEqual(releaseNotes.provenance, .homebrewMetadata)
  }

  func testReleaseNotesFetcherRejectsMalformedAndOversizedContent() async throws {
    let url = URL(string: "https://example.com/notes")!
    let malformedFetcher = ReleaseNotesFetcher(
      loader: StubReleaseNotesLoader(
        response: Self.httpResponse(
          url: url,
          data: Data(repeating: 0, count: 128)
        )))
    await XCTAssertThrowsErrorAsync(try await malformedFetcher.fetchMarkup(from: url)) {
      XCTAssertEqual($0 as? ReleaseNotesFetchError, .unusableText)
    }

    let oversizedFetcher = ReleaseNotesFetcher(
      loader: StubReleaseNotesLoader(
        response: Self.httpResponse(url: url, data: Data("12345".utf8))),
      maximumResponseSize: 4
    )
    await XCTAssertThrowsErrorAsync(try await oversizedFetcher.fetchMarkup(from: url)) {
      XCTAssertEqual($0 as? ReleaseNotesFetchError, .oversized)
    }
  }

  func testSignedCatalogAcceptsValidRemoteDocument() async throws {
    let fixture = try makeSignedCatalogFixture(schemaVersion: 1)
    let client = SignedReleaseNotesCatalogClient(
      configuration: .init(
        isEnabled: true,
        remoteURL: fixture.url,
        publicKey: fixture.publicKey,
        maximumEnvelopeSize: 64 * 1_024
      ),
      bundledCatalogData: fixture.bundled,
      loader: StubCatalogLoader(
        response: Self.httpResponse(url: fixture.url, data: fixture.envelope))
    )

    let loaded = try await client.load()
    XCTAssertEqual(loaded.origin, .remote)
    XCTAssertEqual(loaded.document.definitions.first?.keys, ["remote-app"])
  }

  func testSignedCatalogLiveConfigurationRequiresACompleteHTTPSKeyPair() {
    let publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      .base64EncodedString()
    let valid = SignedReleaseNotesCatalogClient.Configuration.live(environment: [
      "LATEST_RELEASE_NOTES_CATALOG_URL": "https://example.com/release-notes.json",
      "LATEST_RELEASE_NOTES_CATALOG_PUBLIC_KEY": publicKey,
    ])
    XCTAssertTrue(valid.isEnabled)
    XCTAssertEqual(valid.remoteURL?.absoluteString, "https://example.com/release-notes.json")

    for environment in [
      ["LATEST_RELEASE_NOTES_CATALOG_URL": "https://example.com/release-notes.json"],
      [
        "LATEST_RELEASE_NOTES_CATALOG_URL": "http://example.com/release-notes.json",
        "LATEST_RELEASE_NOTES_CATALOG_PUBLIC_KEY": publicKey,
      ],
      [
        "LATEST_RELEASE_NOTES_CATALOG_URL": "https://user@example.com/release-notes.json",
        "LATEST_RELEASE_NOTES_CATALOG_PUBLIC_KEY": publicKey,
      ],
      [
        "LATEST_RELEASE_NOTES_CATALOG_URL": "https://example.com/release-notes.json",
        "LATEST_RELEASE_NOTES_CATALOG_PUBLIC_KEY": "invalid",
      ],
    ] {
      XCTAssertFalse(
        SignedReleaseNotesCatalogClient.Configuration.live(environment: environment).isEnabled)
    }
  }

  func testSignedCatalogRejectsWrongSignatureAndUsesBundledLastKnownGood() async throws {
    var fixture = try makeSignedCatalogFixture(schemaVersion: 1)
    var envelope = try JSONDecoder().decode(
      SignedReleaseNotesCatalogEnvelope.self, from: fixture.envelope)
    envelope = SignedReleaseNotesCatalogEnvelope(
      schemaVersion: envelope.schemaVersion,
      payload: envelope.payload,
      signature: Data(repeating: 0, count: envelope.signature.count)
    )
    fixture.envelope = try JSONEncoder().encode(envelope)
    let client = catalogClient(fixture: fixture)

    let loaded = try await client.load()
    XCTAssertEqual(loaded.origin, .bundledFallback(.invalidSignature))
    XCTAssertEqual(loaded.document.definitions.first?.keys, ["bundled-app"])
  }

  func testSignedCatalogRejectsUnsupportedSchemaAndUsesBundledLastKnownGood() async throws {
    let fixture = try makeSignedCatalogFixture(schemaVersion: 99)
    let loaded = try await catalogClient(fixture: fixture).load()

    XCTAssertEqual(loaded.origin, .bundledFallback(.invalidCatalog))
    XCTAssertEqual(loaded.document.definitions.first?.keys, ["bundled-app"])
  }

  func testSignedCatalogRejectsUnsupportedEnvelopeSchemaAndUsesBundledLastKnownGood() async throws {
    var fixture = try makeSignedCatalogFixture(schemaVersion: 1)
    let validEnvelope = try JSONDecoder().decode(
      SignedReleaseNotesCatalogEnvelope.self, from: fixture.envelope)
    fixture.envelope = try JSONEncoder().encode(
      SignedReleaseNotesCatalogEnvelope(
        schemaVersion: 99,
        payload: validEnvelope.payload,
        signature: validEnvelope.signature
      ))

    let loaded = try await catalogClient(fixture: fixture).load()
    XCTAssertEqual(loaded.origin, .bundledFallback(.invalidEnvelopeSchema))
    XCTAssertEqual(loaded.document.definitions.first?.keys, ["bundled-app"])
  }

  func testSignedCatalogOfflineAndDisabledModesUseBundledLastKnownGood() async throws {
    let fixture = try makeSignedCatalogFixture(schemaVersion: 1)
    let offlineClient = SignedReleaseNotesCatalogClient(
      configuration: .init(
        isEnabled: true,
        remoteURL: fixture.url,
        publicKey: fixture.publicKey,
        maximumEnvelopeSize: 64 * 1_024
      ),
      bundledCatalogData: fixture.bundled,
      loader: OfflineCatalogLoader()
    )
    let offline = try await offlineClient.load()
    XCTAssertEqual(offline.origin, .bundledFallback(.network))

    let disabled = try await SignedReleaseNotesCatalogClient(
      configuration: .disabled,
      bundledCatalogData: fixture.bundled
    ).load()
    XCTAssertEqual(disabled.origin, .bundledFallback(.disabled))
  }

  func testSignedCatalogClassifiesStreamingSizeLimitAsOversized() async throws {
    let fixture = try makeSignedCatalogFixture(schemaVersion: 1)
    let client = SignedReleaseNotesCatalogClient(
      configuration: .init(
        isEnabled: true,
        remoteURL: fixture.url,
        publicKey: fixture.publicKey,
        maximumEnvelopeSize: 64 * 1_024
      ),
      bundledCatalogData: fixture.bundled,
      loader: OversizedCatalogLoader()
    )

    let loaded = try await client.load()
    XCTAssertEqual(loaded.origin, .bundledFallback(.oversized))
    XCTAssertEqual(loaded.document.definitions.first?.keys, ["bundled-app"])
  }

  func testSignedCatalogPersistsAndRevalidatesVerifiedRemoteCatalog() async throws {
    let fixture = try makeSignedCatalogFixture(schemaVersion: 1)
    let cacheDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheURL = cacheDirectory.appendingPathComponent("catalog.plist")
    let cache = ReleaseNotesCatalogDiskCache(url: cacheURL)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let configuration = SignedReleaseNotesCatalogClient.Configuration(
      isEnabled: true,
      remoteURL: fixture.url,
      publicKey: fixture.publicKey,
      maximumEnvelopeSize: 64 * 1_024
    )
    let successfulResponse = Self.httpResponse(
      url: fixture.url,
      statusCode: 200,
      data: fixture.envelope,
      headerFields: ["ETag": "\"catalog-v1\""]
    )

    let remote = try await SignedReleaseNotesCatalogClient(
      configuration: configuration,
      bundledCatalogData: fixture.bundled,
      loader: StubCatalogLoader(response: successfulResponse),
      cache: cache
    ).load()
    XCTAssertEqual(remote.origin, .remote)
    XCTAssertEqual(cache.load()?.eTag, "\"catalog-v1\"")

    let offline = try await SignedReleaseNotesCatalogClient(
      configuration: configuration,
      bundledCatalogData: fixture.bundled,
      loader: OfflineCatalogLoader(),
      cache: cache
    ).load()
    XCTAssertEqual(offline.origin, .remoteCacheFallback(.network))
    XCTAssertEqual(offline.document.definitions.first?.keys, ["remote-app"])

    let notModified = try await SignedReleaseNotesCatalogClient(
      configuration: configuration,
      bundledCatalogData: fixture.bundled,
      loader: StubCatalogLoader(
        response: Self.httpResponse(
          url: fixture.url,
          statusCode: 304,
          data: Data()
        )),
      cache: cache
    ).load()
    XCTAssertEqual(notModified.origin, .remoteCache)
    XCTAssertEqual(notModified.document.definitions.first?.keys, ["remote-app"])
  }

  private static func httpResponse(url: URL, data: Data) -> ReleaseNotesFetchResponse {
    httpResponse(url: url, statusCode: 200, data: data)
  }

  private static func httpResponse(
    url: URL,
    statusCode: Int,
    data: Data,
    headerFields: [String: String] = [:]
  ) -> ReleaseNotesFetchResponse {
    var headers = headerFields
    headers["Content-Type"] = "application/json"
    headers["Content-Length"] = "\(data.count)"
    let response = HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
    return ReleaseNotesFetchResponse(data: data, response: response)
  }

  private func catalogClient(fixture: SignedCatalogFixture) -> SignedReleaseNotesCatalogClient {
    SignedReleaseNotesCatalogClient(
      configuration: .init(
        isEnabled: true,
        remoteURL: fixture.url,
        publicKey: fixture.publicKey,
        maximumEnvelopeSize: 64 * 1_024
      ),
      bundledCatalogData: fixture.bundled,
      loader: StubCatalogLoader(
        response: Self.httpResponse(url: fixture.url, data: fixture.envelope))
    )
  }

  private func makeSignedCatalogFixture(schemaVersion: Int) throws -> SignedCatalogFixture {
    let bundled = try JSONEncoder().encode([Self.catalogDefinition(key: "bundled-app")])
    let remoteDocument = ReleaseNotesCatalogDocument(
      schemaVersion: schemaVersion,
      definitions: [Self.catalogDefinition(key: "remote-app")]
    )
    let payload = try JSONEncoder().encode(remoteDocument)
    let privateKey = Curve25519.Signing.PrivateKey()
    let envelope = SignedReleaseNotesCatalogEnvelope(
      schemaVersion: SignedReleaseNotesCatalogEnvelope.supportedSchemaVersion,
      payload: payload,
      signature: try privateKey.signature(for: payload)
    )
    return SignedCatalogFixture(
      url: URL(string: "https://catalog.example.com/release-notes.json")!,
      publicKey: privateKey.publicKey.rawRepresentation,
      bundled: bundled,
      envelope: try JSONEncoder().encode(envelope)
    )
  }

  private static func catalogDefinition(key: String) -> ReleaseNotesSourceDefinition {
    ReleaseNotesSourceDefinition(
      keys: [key],
      homebrewTokens: [],
      kind: .changelog,
      urlTemplate: "https://example.com/changelog/{version}",
      versionPrefix: .exact,
      knownFallbackKey: nil,
      allowsLatestFallback: false
    )
  }

}

private struct SignedCatalogFixture {
  let url: URL
  let publicKey: Data
  let bundled: Data
  var envelope: Data
}

private struct StubReleaseNotesLoader: ReleaseNotesHTTPDataLoading {
  let response: ReleaseNotesFetchResponse

  func load(_ request: URLRequest, maximumResponseSize: Int) async throws
    -> ReleaseNotesFetchResponse
  {
    response
  }
}

private struct StubCatalogLoader: ReleaseNotesHTTPDataLoading {
  let response: ReleaseNotesFetchResponse

  func load(_ request: URLRequest, maximumResponseSize: Int) async throws
    -> ReleaseNotesFetchResponse
  {
    response
  }
}

private struct OfflineCatalogLoader: ReleaseNotesHTTPDataLoading {
  private struct Offline: Error {}

  func load(_ request: URLRequest, maximumResponseSize: Int) async throws
    -> ReleaseNotesFetchResponse
  {
    throw Offline()
  }
}

private struct OversizedCatalogLoader: ReleaseNotesHTTPDataLoading {
  func load(_ request: URLRequest, maximumResponseSize: Int) async throws
    -> ReleaseNotesFetchResponse
  {
    throw ReleaseNotesFetchError.oversized
  }
}

private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ errorHandler: (Error) -> Void = { _ in },
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw", file: file, line: line)
  } catch {
    errorHandler(error)
  }
}
