//
//  ComplexityBenchmarkTest.swift
//  Latest Tests
//
//  Created by ertyoii on 31.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-05-31.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import XCTest

@testable import Latest

@MainActor
final class ComplexityBenchmarkTest: XCTestCase {
  func testRepositoryCachePreservesExpiredDataAndHTTPValidators() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheURL = directory.appendingPathComponent("repository.json")
    let suiteName = "Latest.RepositoryCacheTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      try? FileManager.default.removeItem(at: directory)
      defaults.removePersistentDomain(forName: suiteName)
    }

    let cache = UpdateRepositoryCache(
      cacheURL: cacheURL,
      userDefaultsKey: "repository.updated",
      userDefaults: defaults
    )
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: URL(string: "https://example.com/repository.json")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["ETag": "\"catalog-v2\"", "Last-Modified": "Wed, 01 Jul 2026 12:00:00 GMT"]
      ))
    let payload = Data("[]".utf8)

    cache.store(payload, response: response)
    XCTAssertEqual(cache.cachedData(), payload)
    XCTAssertEqual(cache.validators.eTag, "\"catalog-v2\"")
    XCTAssertEqual(cache.validators.lastModified, "Wed, 01 Jul 2026 12:00:00 GMT")

    defaults.set(Date.timeIntervalSinceReferenceDate - 7_200, forKey: "repository.updated")
    XCTAssertNil(cache.cachedData())
    XCTAssertEqual(cache.cachedData(allowExpired: true), payload)

    cache.markFresh()
    XCTAssertEqual(cache.cachedData(), payload)

    cache.invalidate()
    XCTAssertNil(cache.cachedData(allowExpired: true), "Rejected data must not remain a fallback")
    XCTAssertNil(cache.validators.eTag, "A retry must not revalidate a rejected payload")
    XCTAssertNil(cache.validators.lastModified)
    let replacement = Data("[{}]".utf8)
    cache.store(replacement, response: response)
    XCTAssertEqual(cache.cachedData(), replacement)
  }

  func testCompactRepositoryIndexRoundTripAndInvalidation() throws {
    let sourceData = try makeRepositoryData(count: 30, appArtifactCount: 18)
    let decodedEntries = try JSONDecoder().decode([UpdateRepository.Entry].self, from: sourceData)
    let appEntries = decodedEntries.filter { !$0.names.isEmpty }
    let index = UpdateRepositoryCompactIndex(
      sourceData: sourceData,
      sourceEntryCount: decodedEntries.count,
      entries: appEntries
    )

    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let data = try encoder.encode(index)
    let restored = try PropertyListDecoder().decode(UpdateRepositoryCompactIndex.self, from: data)

    XCTAssertTrue(restored.matches(sourceData))
    XCTAssertEqual(restored.sourceEntryCount, decodedEntries.count)
    XCTAssertEqual(restored.entries.map(\.token), appEntries.map(\.token))
    XCTAssertEqual(restored.entries.map(\.names), appEntries.map(\.names))
    XCTAssertEqual(restored.entries.map(\.bundleIdentifiers), appEntries.map(\.bundleIdentifiers))

    var changedSourceData = sourceData
    changedSourceData.append(0)
    XCTAssertFalse(restored.matches(changedSourceData))
  }

  func testComplexityBenchmarks() async throws {
    guard FileManager.default.fileExists(atPath: Self.benchmarkFlagURL.path) else {
      throw XCTSkip("Run script/benchmark_complexity.sh to execute complexity benchmarks.")
    }

    #if DEBUG
      let configuration = "Debug"
    #else
      let configuration = "Release"
    #endif
    FileHandle.standardError.write(
      Data("BENCHMARK_CONFIGURATION configuration=\(configuration) samples=30\n".utf8))

    let settings = try isolatedAppListSettings(for: self)

    let dataStoreBundles = makeBundles(count: 2_000)
    let snapshotApps = makeApps(count: 1_500)
    let searchSnapshot = AppListSnapshot(
      withApps: snapshotApps, filterQuery: nil, settings: settings)
    let checkingSnapshot = AppListSnapshot(
      withApps: snapshotApps, filterQuery: nil, settings: settings, checkingGeneration: 1)
    let searchQueries = (0..<40).map { "Benchmark App \($0)" }
    let lookupApps = Array(snapshotApps.prefix(400))
    let versionPairs = makeVersionPairs(count: 80_000)
    let releaseNotesMarkup = makeReleaseNotesMarkup(sectionCount: 300)
    let releaseNotesCacheDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "Latest-ReleaseNotes-Benchmark-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: releaseNotesCacheDirectory) }
    let releaseNotesCache = ReleaseNotesPersistentCache(directoryURL: releaseNotesCacheDirectory)
    let releaseNotesCachePayload = ReleaseNotesPersistentPayload(
      richTextData: Data(repeating: 0x41, count: 4_096),
      qualityRawValue: ReleaseNotesQuality.genuine.rawValue,
      provenanceRawValue: ReleaseNotesProvenance.changelog.rawValue,
      storedAt: Date()
    )
    for index in 0..<100 {
      await releaseNotesCache.store(releaseNotesCachePayload, forKey: "benchmark-\(index)")
    }
    let repositoryCatalogData = try makeRepositoryData(count: 7_737, appArtifactCount: 4_168)
    let decodedRepositoryEntries = try JSONDecoder().decode(
      [UpdateRepository.Entry].self, from: repositoryCatalogData)
    let compactRepositoryIndex = UpdateRepositoryCompactIndex(
      sourceData: repositoryCatalogData,
      sourceEntryCount: decodedRepositoryEntries.count,
      entries: decodedRepositoryEntries.filter { !$0.names.isEmpty }
    )
    let compactIndexEncoder = PropertyListEncoder()
    compactIndexEncoder.outputFormat = .binary
    let compactRepositoryData = try compactIndexEncoder.encode(compactRepositoryIndex)
    let repositoryEntries = try makeRepositoryEntries(count: 3_000)
    let repositoryCandidateGroups = makeRepositoryCandidateGroups(from: repositoryEntries)
    let bundleCollectionRoot = try makeBundleCollectionRoot(
      appCount: 250, fillerDirectoryCount: 250)
    defer { try? FileManager.default.removeItem(at: bundleCollectionRoot) }

    benchmark("app_data_store_update_batch", iterations: 30) {
      let store = AppDataStore()
      store.set(appBundles: Set(dataStoreBundles))

      var checksum = 0
      for index in stride(from: 0, to: dataStoreBundles.count, by: 2) {
        let bundle = dataStoreBundles[index]
        let remoteVersion = Version(versionNumber: "2.\(index)", buildNumber: nil)
        let app = store.set(
          .success(makeUpdate(for: bundle, remoteVersion: remoteVersion)), for: bundle)
        if app.updateAvailable {
          checksum &+= 1
        }
      }

      return checksum
    }

    benchmark("app_list_snapshot_build_and_lookup", iterations: 30) {
      let snapshot = AppListSnapshot(
        withApps: snapshotApps, filterQuery: nil, settings: settings)
      var checksum = snapshot.entries.count
      for app in lookupApps {
        checksum &+= snapshot.firstIndex(of: app) ?? 0
      }
      return checksum
    }

    benchmark("app_list_checking_snapshot", iterations: 30) {
      AppListSnapshot(
        withApps: snapshotApps.reversed(), filterQuery: nil, settings: settings,
        checkingGeneration: 1, previous: checkingSnapshot
      ).entries.count
    }

    benchmark("app_list_search_refilter", iterations: 30) {
      var checksum = 0
      for query in searchQueries {
        checksum &+= searchSnapshot.refiltered(with: query).entries.count
      }
      return checksum
    }

    benchmark("app_list_search_full_rebuild", iterations: 30) {
      var checksum = 0
      for query in searchQueries {
        checksum &+=
          AppListSnapshot(
            withApps: snapshotApps, filterQuery: query, settings: settings
          ).entries.count
      }
      return checksum
    }

    let metadataVersions = (0..<2_000).map { "1.2.\($0)" }
    benchmark("version_metadata_parse", iterations: 30) {
      var checksum = 0
      for value in metadataVersions {
        let version = Version(
          versionNumber: VersionParser.parse(versionNumber: value),
          buildNumber: VersionParser.parse(buildNumber: value))
        checksum &+= version.versionNumber?.count ?? 0
      }
      return checksum
    }

    let entityText = String(
      repeating: "Fixed &quot;Café&quot; &amp; &#x1F680; &#169; &lt;widget&gt;.\n", count: 1_000)
    benchmark("release_notes_entity_decode", iterations: 30) {
      ReleaseNotesMarkup.decodingHTMLEntities(in: entityText).utf8.count
    }

    await benchmarkAsync("update_progress_burst", iterations: 30) {
      let queue = UpdateQueue()
      let started = expectation(description: "Benchmark operation started")
      let operation = BenchmarkUpdateOperation(started: started)
      queue.addOperation(operation)
      await fulfillment(of: [started], timeout: 2)
      let stream = queue.stateChanges(for: operation.appIdentifier).changes
      let terminal = expectation(description: "Benchmark terminal progress")
      let observation = Task {
        for await state in stream {
          if case .error = state {
            terminal.fulfill()
            break
          }
        }
      }
      defer { observation.cancel() }
      for bytes in 0..<1_000 {
        operation.progressState = .downloading(loadedSize: Int64(bytes), totalSize: 1_000)
      }
      operation.finish(with: URLError(.cannotWriteToFile))
      await fulfillment(of: [terminal], timeout: 2)
      return 1_000
    }

    benchmark("version_comparison_repeated_parse", iterations: 30) {
      var checksum = 0
      for pair in versionPairs {
        if pair.local.comparisonForUpdate(to: pair.remote) == .older {
          checksum &+= 1
        }
      }
      return checksum
    }

    try benchmark("release_notes_markup_parse_and_render", iterations: 30) {
      try ReleaseNotesMarkup.attributedString(
        from: releaseNotesMarkup,
        baseURL: URL(string: "https://example.com/changelog"),
        relevantVersion: "150.0"
      ).get().length
    }

    for count in [50, 500] {
      let mixedMarkup = String(
        repeating: "Fixed <strong>important</strong> behavior using `<i>literal</i>`.\n\n",
        count: count)
      benchmark("release_notes_mixed_code_\(count)", iterations: 30) {
        ReleaseNotesDocument.prepare(mixedMarkup).characters.count
      }
    }

    await benchmarkAsync("release_notes_persistent_cache_read", iterations: 30) {
      var checksum = 0
      for index in 0..<100 {
        checksum &+=
          await releaseNotesCache.payload(forKey: "benchmark-\(index)")?.richTextData.count ?? 0
      }
      return checksum
    }

    try benchmark("update_repository_catalog_decode", iterations: 30) {
      let entries = try JSONDecoder().decode(
        [UpdateRepository.Entry].self, from: repositoryCatalogData)
      return entries.reduce(into: 0) { checksum, entry in
        checksum &+= entry.names.count
        checksum &+= entry.bundleIdentifiers.count
      }
    }

    try benchmark("update_repository_compact_index_decode", iterations: 30) {
      let index = try PropertyListDecoder().decode(
        UpdateRepositoryCompactIndex.self, from: compactRepositoryData)
      let entries = index.entries
      return entries.reduce(into: 0) { checksum, entry in
        checksum &+= entry.names.count
        checksum &+= entry.bundleIdentifiers.count
      }
    }

    benchmark("update_repository_entry_metadata_and_matching", iterations: 30) {
      var checksum = 0
      for entry in repositoryEntries {
        checksum &+= entry.version.versionNumber?.count ?? 0
        if entry.releaseNotes != nil {
          checksum &+= 1
        }
      }

      for group in repositoryCandidateGroups {
        checksum &+=
          UpdateRepository.preferredEntry(from: group.entries, for: group.bundleIdentifier)?.token
          .count ?? 0
      }

      return checksum
    }

    benchmark("update_repository_lazy_metadata_and_matching", iterations: 30) {
      var checksum = 0
      for (index, group) in repositoryCandidateGroups.enumerated() {
        guard
          let entry = UpdateRepository.preferredEntry(
            from: group.entries, for: group.bundleIdentifier)
        else {
          continue
        }
        checksum &+= entry.token.count
        if index < 40 {
          checksum &+= entry.version.versionNumber?.count ?? 0
          if entry.releaseNotes != nil {
            checksum &+= 1
          }
        }
      }

      return checksum
    }

    benchmark("bundle_collection_path_filtering", iterations: 30) {
      BundleCollector.collectBundles(at: bundleCollectionRoot).count
    }

    let overlapBundles = Array(dataStoreBundles.prefix(100))
    benchmark("update_result_acceptance_overlap", iterations: 30) {
      let store = AppDataStore()
      let generations = UpdateCheckGenerationTracker()
      let staleGeneration = generations.begin()
      DispatchQueue.concurrentPerform(iterations: 8) { _ in
        let generation = generations.begin()
        for bundle in overlapBundles {
          _ = generations.withCurrent(generation) { store.set(appBundle: bundle) }
        }
      }
      let latest = generations.begin()
      for bundle in overlapBundles {
        _ = generations.withCurrent(latest) { store.set(appBundle: bundle) }
      }
      let rejected: Void? = generations.withCurrent(staleGeneration) { store.set(appBundles: []) }
      XCTAssertNil(rejected)
      XCTAssertEqual(store.apps.count, overlapBundles.count)
      return store.apps.count
    }

    await benchmarkAsync("update_check_scheduler_fixture", iterations: 30) {
      await self.runStructuredUpdateCheckBatch(taskCount: 120, maximumConcurrentChecks: 6)
    }
  }

  private static var benchmarkFlagURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("build/run-complexity-benchmarks", isDirectory: false)
  }

  private func benchmark(_ name: String, iterations: Int, block: () throws -> Int) rethrows {
    var samples = [Double]()
    var checksum = 0

    for _ in 0..<iterations {
      let start = DispatchTime.now().uptimeNanoseconds
      checksum &+= try block()
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(Double(end - start) / 1_000_000)
    }

    let minSample = samples.min() ?? 0
    let maxSample = samples.max() ?? 0
    let average = samples.reduce(0, +) / Double(samples.count)
    let sortedSamples = samples.sorted()
    let median = percentile(0.50, in: sortedSamples)
    let p95 = percentile(0.95, in: sortedSamples)
    emitBenchmarkLine(
      name: name,
      iterations: iterations,
      minimum: minSample,
      average: average,
      median: median,
      p95: p95,
      maximum: maxSample,
      checksum: checksum
    )
  }

  private func benchmarkAsync(
    _ name: String,
    iterations: Int,
    block: () async throws -> Int
  ) async rethrows {
    var samples = [Double]()
    var checksum = 0

    for _ in 0..<iterations {
      let start = DispatchTime.now().uptimeNanoseconds
      checksum &+= try await block()
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(Double(end - start) / 1_000_000)
    }

    let sortedSamples = samples.sorted()
    emitBenchmarkLine(
      name: name,
      iterations: iterations,
      minimum: samples.min() ?? 0,
      average: samples.reduce(0, +) / Double(samples.count),
      median: percentile(0.50, in: sortedSamples),
      p95: percentile(0.95, in: sortedSamples),
      maximum: samples.max() ?? 0,
      checksum: checksum
    )
  }

  /// Measures the production structured-concurrency scheduler with the same
  /// deterministic workload used for the before measurement.
  private func runStructuredUpdateCheckBatch(
    taskCount: Int,
    maximumConcurrentChecks: Int
  ) async -> Int {
    let execution = await BoundedUpdateCheckExecutor(
      maximumConcurrentTasks: maximumConcurrentChecks
    ).run(Array(0..<taskCount)) { index in
      try await Task.sleep(for: .milliseconds(1))
      return index
    }
    return execution.results.reduce(into: 0) { checksum, result in
      if case .success(let value) = result.result {
        checksum &+= value
      }
    }
  }

  private func percentile(_ percentile: Double, in sortedSamples: [Double]) -> Double {
    guard !sortedSamples.isEmpty else { return 0 }
    let index = Int((Double(sortedSamples.count - 1) * percentile).rounded(.up))
    return sortedSamples[index]
  }

  private func emitBenchmarkLine(
    name: String,
    iterations: Int,
    minimum: Double,
    average: Double,
    median: Double,
    p95: Double,
    maximum: Double,
    checksum: Int
  ) {
    let line = String(
      format:
        "BENCHMARK name=%@ iterations=%d min_ms=%.3f avg_ms=%.3f median_ms=%.3f p95_ms=%.3f max_ms=%.3f checksum=%d",
      name,
      iterations,
      minimum,
      average,
      median,
      p95,
      maximum,
      checksum
    )
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }

  private func makeBundles(count: Int) -> [App.Bundle] {
    (0..<count).map { index in
      App.Bundle(
        version: Version(versionNumber: "1.\(index)", buildNumber: "\(index)"),
        name: "Benchmark App \(index)",
        bundleIdentifier: "com.example.benchmark.\(index)",
        fileURL: URL(fileURLWithPath: "/Applications/Benchmark-\(index).app", isDirectory: true),
        source: .sparkle
      )
    }
  }

  private func makeApps(count: Int) -> [App] {
    makeBundles(count: count).enumerated().map { index, bundle in
      let update: Result<App.Update, Error>?
      if index % 3 == 0 {
        update = .success(
          makeUpdate(
            for: bundle, remoteVersion: Version(versionNumber: "2.\(index)", buildNumber: nil)))
      } else {
        update = nil
      }

      return App(bundle: bundle, update: update, isIgnored: index % 17 == 0)
    }
  }

  private func makeUpdate(for bundle: App.Bundle, remoteVersion: Version) -> App.Update {
    App.Update(
      app: bundle,
      remoteVersion: remoteVersion,
      minimumOSVersion: nil,
      source: .sparkle,
      date: nil,
      releaseNotes: nil,
      updateAction: .external(label: "Benchmark") { _ in }
    )
  }

  private func makeVersionPairs(count: Int) -> [(local: Version, remote: Version)] {
    (0..<count).map { index in
      let major = index % 10
      let minor = (index / 10) % 50
      let patch = (index / 500) % 20
      return (
        local: Version(
          versionNumber: "\(major).\(minor).\(patch)-stable.\(index)", buildNumber: "\(index)"),
        remote: Version(
          versionNumber: "\(major).\(minor).\(patch + 1)-stable.\(index + 10)",
          buildNumber: "\(index + 10)")
      )
    }
  }

  private func makeReleaseNotesMarkup(sectionCount: Int) -> String {
    (0..<sectionCount).map { index in
      """
      <h2>Version \(index).0</h2>
      <ul>
      \t<li>Improved update discovery performance for application \(index).</li>
      \t<li>Fixed a release note rendering issue in section \(index).</li>
      \t<li>Added compatibility improvements for macOS \(index).</li>
      </ul>
      """
    }.joined(separator: "\n")
  }

  private func makeRepositoryEntries(count: Int) throws -> [UpdateRepository.Entry] {
    let data = try makeRepositoryData(count: count, appArtifactCount: count)
    return try JSONDecoder().decode([UpdateRepository.Entry].self, from: data)
  }

  private func makeRepositoryData(count: Int, appArtifactCount: Int) throws -> Data {
    let objects: [[String: Any]] = (0..<count).map { index in
      let group = index / 3
      let channel = index % 3
      let token: String
      switch channel {
      case 1:
        token = "repo-benchmark-\(group)@beta"
      case 2:
        token = "repo-benchmark-\(group)-for-it-admins"
      default:
        token = "repo-benchmark-\(group)"
      }

      let appName = "Repo Benchmark \(group).app"
      let bundleIdentifier = "com.example.repository.\(group)"
      let artifacts: [[String: Any]]
      if index < appArtifactCount {
        artifacts = [
          [
            "app": [appName],
            "uninstall": [
              [
                "quit": bundleIdentifier
              ]
            ],
          ]
        ]
      } else {
        artifacts = [["font": ["Benchmark-\(index).ttf"]]]
      }

      return [
        "token": token,
        "version": "\(group % 20).\(index % 50).\(index % 9),\(index)",
        "name": ["Repo Benchmark \(group)"],
        "homepage": "https://example.com/repo-\(group)",
        "url": "https://example.com/repo-\(group).zip",
        "desc": "Repository benchmark entry \(index) with metadata.",
        "artifacts": artifacts,
        "depends_on": [
          "macos": [:]
        ],
      ]
    }

    return try JSONSerialization.data(withJSONObject: objects)
  }

  private func makeRepositoryCandidateGroups(
    from entries: [UpdateRepository.Entry]
  ) -> [(bundleIdentifier: String, entries: [UpdateRepository.Entry])] {
    stride(from: 0, to: entries.count - 2, by: 3).map { index in
      (
        bundleIdentifier: "com.example.repository.\(index / 3)",
        entries: Array(entries[index..<(index + 3)])
      )
    }
  }

  private func makeBundleCollectionRoot(appCount: Int, fillerDirectoryCount: Int) throws -> URL {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent("LatestComplexityBenchmark-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

    for index in 0..<fillerDirectoryCount {
      let directoryURL =
        rootURL
        .appendingPathComponent("Nested-\(index / 20)", isDirectory: true)
        .appendingPathComponent("Folder-\(index)", isDirectory: true)
      try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    let setappURL = rootURL.appendingPathComponent("Setapp", isDirectory: true)
    try fileManager.createDirectory(at: setappURL, withIntermediateDirectories: true)
    for index in 0..<50 {
      try makeSyntheticApp(
        at: setappURL.appendingPathComponent("Excluded-\(index).app", isDirectory: true),
        index: index
      )
    }

    for index in 0..<appCount {
      let parentURL = rootURL.appendingPathComponent("Apps-\(index / 25)", isDirectory: true)
      try makeSyntheticApp(
        at: parentURL.appendingPathComponent("Benchmark-\(index).app", isDirectory: true),
        index: index
      )
    }

    return rootURL
  }

  private func makeSyntheticApp(at appURL: URL, index: Int) throws {
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let infoPlist: [String: Any] = [
      "CFBundleIdentifier": "com.example.synthetic.\(index)",
      "CFBundleName": "Synthetic \(index)",
      "CFBundleShortVersionString": "1.\(index)",
      "CFBundleVersion": "\(index)",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: infoPlist, format: .xml, options: 0)
    try data.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))
  }

}

private final class BenchmarkUpdateOperation: UpdateOperation, @unchecked Sendable {
  private let started: XCTestExpectation

  init(started: XCTestExpectation) {
    self.started = started
    super.init(
      bundleIdentifier: "test.benchmark", appIdentifier: URL(fileURLWithPath: "/tmp/Benchmark.app"))
  }

  override func execute() {
    super.execute()
    started.fulfill()
  }
}
