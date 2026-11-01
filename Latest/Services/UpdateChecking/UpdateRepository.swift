//
//  UpdateRepository.swift
//  Latest
//
//  Created by Max Langer on 01.10.23.
//  Copyright © 2023 Max Langer. All rights reserved.
//

import Foundation
import OSLog
import Synchronization

/// User defaults key for storing the last cache update date.
private let UpdateDateKey = "UpdateDateKey"

private let updateRepositoryLogger = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "com.max-langer.Latest",
  category: "Repository"
)
private let updateRepositorySignposter = OSSignposter(
  subsystem: Bundle.main.bundleIdentifier ?? "com.max-langer.Latest",
  category: "RepositoryPerformance"
)

/// A storage that fetches update information from an online source.
///
/// Can be asked for update version information for a given application bundle.
final class UpdateRepository: Sendable {
  private static let locallyExcludedBundleIdentifiers: Set<String> = [
    // OpenAI's Codex desktop app was renamed to ChatGPT but remains a separate
    // product from the consumer ChatGPT cask. Name-only matching would assign
    // com.openai.codex the unrelated chatgpt Homebrew version.
    "com.openai.codex"
  ]

  private static let reusableRepositories = UpdateRepositoryReuseCache()

  /// Queue on which requests will be handled.
  private let queue = DispatchQueue(label: "repositoryQueue")

  private let dataSource = RemoteDataSource()

  // MARK: - Init

  let fetchCompletedGroup = DispatchGroup()

  fileprivate let createdAt = Date.timeIntervalSinceReferenceDate

  private struct State {
    var finalizeHandler: (@Sendable (UpdateRepository, Bool) -> Void)?
    var pendingRequests: [@Sendable () -> Void]? = []
    var entryMatcher = EntryMatcher(entries: [], unsupportedBundleIdentifiers: [])
    var loadedURLTypes = Set<RemoteURL>()
  }
  private let state: Mutex<State>

  fileprivate init(finalizeHandler: (@Sendable (UpdateRepository, Bool) -> Void)? = nil) {
    self.state = Mutex(State(finalizeHandler: finalizeHandler))

    fetchCompletedGroup.enter()
    fetchCompletedGroup.notify(queue: .main) { [weak self] in
      self?.finalize()
    }
  }

  /// Returns a new repository with up to date update information.
  static func newRepository() -> UpdateRepository {
    reusableRepositories.repository()
  }

  // MARK: - Accessors

  /// Waits for the catalog once, then returns the matched entry without copying its metadata.
  func entry(for bundle: App.Bundle) async -> Entry? {
    await withCheckedContinuation { continuation in
      let lookup: @Sendable () -> Void = { [self] in
        continuation.resume(returning: state.withLock { $0.entryMatcher.entry(for: bundle) })
      }
      let queued = state.withLock { state in
        guard state.pendingRequests != nil else { return false }
        state.pendingRequests?.append(lookup)
        return true
      }
      if !queued { lookup() }
    }
  }

  /// Sets the given entries and performs pending requests.
  private func finalize() {
    queue.async { [weak self] in
      guard let self else { return }
      let completed = self.state.withLock { state in
        let requests = state.pendingRequests
        state.pendingRequests = nil
        let handler = state.finalizeHandler
        state.finalizeHandler = nil
        return (requests, handler, state.loadedURLTypes)
      }
      guard let requests = completed.0 else {
        assertionFailure("Finalize must only be called once")
        return
      }
      // Callbacks can reenter the repository; never execute them under its mutex.
      requests.forEach { $0() }
      let isReusable = completed.2 == Set(RemoteURL.allCases)
      updateRepositoryLogger.info(
        "Finalized update repository. loadedURLTypes=\(completed.2.count, privacy: .public) reusable=\(isReusable, privacy: .public)"
      )
      completed.1?(self, isReusable)
    }
  }

  static func preferredEntry(from possibleEntries: [Entry], for bundleIdentifier: String) -> Entry?
  {
    EntryMatcher.preferredEntry(from: possibleEntries, for: bundleIdentifier)
  }

  static func isLocallyExcludedFromHomebrewMatching(_ bundleIdentifier: String) -> Bool {
    locallyExcludedBundleIdentifiers.contains(bundleIdentifier)
  }

  // MARK: - Cache Handling

  /// Loads the repository data.
  fileprivate func load() {
    updateRepositoryLogger.info("Loading update repository sources")
    RemoteURL.allCases.forEach { urlType in
      self.fetchCompletedGroup.enter()

      dataSource.load(urlType) { [weak self] data in
        guard let self else { return }

        self.queue.async {
          defer {
            self.fetchCompletedGroup.leave()
          }
          guard let data else {
            updateRepositoryLogger.info(
              "Repository source \(urlType.rawValue, privacy: .public) returned no data")
            return
          }

          let loaded =
            switch urlType {
            case .repository: self.parse(data)
            case .unsupportedApps: self.loadUnsupportedApps(from: data)
            }
          if loaded {
            self.state.withLock { _ = $0.loadedURLTypes.insert(urlType) }
            updateRepositoryLogger.info(
              "Loaded repository source \(urlType.rawValue, privacy: .public)")
          } else {
            UpdateRepositoryCache(
              cacheURL: urlType.cacheURL, userDefaultsKey: urlType.userDefaultsKey
            ).invalidate()
          }
        }
      }
    }
  }

  /// Parses the given repository data and finishes loading.
  private func parse(_ repositoryData: Data) -> Bool {
    let signpostID = updateRepositorySignposter.makeSignpostID()
    let interval = updateRepositorySignposter.beginInterval(
      "Decode Repository Catalog", id: signpostID)
    let start = DispatchTime.now().uptimeNanoseconds
    defer {
      updateRepositorySignposter.endInterval("Decode Repository Catalog", interval)
    }

    do {
      let compactCache = UpdateRepositoryCompactIndexCache(
        cacheURL: RemoteURL.repository.compactIndexCacheURL
      )
      let sourceEntryCount: Int
      let appEntries: [Entry]
      let usedCompactIndex: Bool
      if let compactIndex = compactCache.load(matching: repositoryData) {
        sourceEntryCount = compactIndex.sourceEntryCount
        appEntries = compactIndex.entries
        usedCompactIndex = true
      } else {
        let entries = try JSONDecoder().decode([Entry].self, from: repositoryData)
        sourceEntryCount = entries.count
        appEntries = entries.filter { !$0.names.isEmpty }
        compactCache.store(
          UpdateRepositoryCompactIndex(
            sourceData: repositoryData,
            sourceEntryCount: sourceEntryCount,
            entries: appEntries
          ))
        usedCompactIndex = false
      }
      state.withLock { $0.entryMatcher.update(entries: appEntries) }
      let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
      updateRepositoryLogger.info(
        "Loaded \(sourceEntryCount, privacy: .public) casks and indexed \(appEntries.count, privacy: .public) app entries in \(duration, privacy: .public) ms compact=\(usedCompactIndex, privacy: .public)"
      )
      return true
    } catch {
      state.withLock { $0.entryMatcher.update(entries: []) }
      updateRepositoryLogger.error(
        "Failed to decode repository catalog: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  private func loadUnsupportedApps(from data: Data) -> Bool {
    guard
      let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String]
    else {
      state.withLock { $0.entryMatcher.update(unsupportedBundleIdentifiers: []) }
      return false
    }

    state.withLock { $0.entryMatcher.update(unsupportedBundleIdentifiers: Set(propertyList)) }
    return true
  }

  // MARK: - Repository URL

  fileprivate enum RemoteURL: String, CaseIterable {

    /// The URL update information is being fetched from.
    case repository = "RepositoryCache"

    /// Duration after which the cache will be invalidated. (1 hour in seconds)
    case unsupportedApps = "UnsupportedApps"

    /// The actual remote URL the information can be fetched from.
    var url: URL? {
      let urlString =
        switch self {
        case .repository:
          "https://formulae.brew.sh/api/cask.json"
        case .unsupportedApps:
          "https://raw.githubusercontent.com/mangerlahn/Latest/main/Latest/Resources/ExcludedAppIdentifiers.plist"
        }

      return URL(string: urlString)
    }

    /// The URL where the cached data will be stored.
    var cacheURL: URL? {
      let name = rawValue
      let pathExtension =
        switch self {
        case .repository:
          "json"
        case .unsupportedApps:
          "plist"
        }

      return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.max-langer.Latest")
        .appendingPathComponent(name).appendingPathExtension(pathExtension)
    }

    var compactIndexCacheURL: URL? {
      guard self == .repository else { return nil }
      return cacheURL?
        .deletingLastPathComponent()
        .appendingPathComponent("RepositoryCompactIndex", isDirectory: false)
        .appendingPathExtension("plist")
    }

    /// Possible fallback data within the binary if the remote content could not be fetched.
    var fallbackData: Data? {
      switch self {
      case .repository:
        return nil
      case .unsupportedApps:
        guard
          let fallbackURL = Bundle.main.url(
            forResource: "ExcludedAppIdentifiers", withExtension: "plist")
        else {
          return nil
        }

        return try? Data(contentsOf: fallbackURL)
      }
    }

    /// The user defaults key used for storing the cache access information.
    var userDefaultsKey: String {
      rawValue + UpdateDateKey
    }

    func isValidPayload(_ data: Data) -> Bool {
      guard !data.isEmpty else { return false }
      switch self {
      case .repository:
        return data.firstNonWhitespaceByte == 0x5B
      case .unsupportedApps:
        return (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String])
          != nil
      }
    }

  }

}

private final class UpdateRepositoryReuseCache: Sendable {
  private struct State: Sendable {
    var repository: UpdateRepository?
    var isLoading = false
  }

  private static let reuseDuration: TimeInterval = 60 * 60

  private let state = Mutex(State())

  func repository() -> UpdateRepository {
    let (repository, startsLoading) = state.withLock { state in
      if let repository = state.repository,
        state.isLoading
          || Date.timeIntervalSinceReferenceDate - repository.createdAt < Self.reuseDuration
      {
        return (repository, false)
      }
      let repository = UpdateRepository { [weak self] repository, isReusable in
        self?.state.withLock { state in
          guard state.repository === repository else { return }
          state.isLoading = false
          if !isReusable { state.repository = nil }
        }
      }
      state.repository = repository
      state.isLoading = true
      return (repository, true)
    }
    // Loading can call back synchronously; start it after releasing the mutex.
    if startsLoading {
      repository.load()
      repository.fetchCompletedGroup.leave()
    }
    return repository
  }

}

private struct EntryMatcher {

  private var entriesByName: [String: [UpdateRepository.Entry]]
  private var unsupportedBundleIdentifiers: Set<String>

  init(entries: [UpdateRepository.Entry], unsupportedBundleIdentifiers: Set<String>) {
    self.entriesByName = Self.entriesByName(entries)
    self.unsupportedBundleIdentifiers = unsupportedBundleIdentifiers
  }

  mutating func update(entries: [UpdateRepository.Entry]) {
    self.entriesByName = Self.entriesByName(entries)
  }

  mutating func update(unsupportedBundleIdentifiers: Set<String>) {
    self.unsupportedBundleIdentifiers = unsupportedBundleIdentifiers
  }

  func entry(for bundle: App.Bundle) -> UpdateRepository.Entry? {
    // Don't return an entry for unsupported apps.
    guard !UpdateRepository.isLocallyExcludedFromHomebrewMatching(bundle.bundleIdentifier),
      !unsupportedBundleIdentifiers.contains(bundle.bundleIdentifier)
    else { return nil }

    // Finding the correct entry is not trivial as there is no bundle identifier stored in an entry. We have a list of app names (could be ambiguous) and a list of bundle identifier guesses.
    // However, both app names and bundle identifiers may occur in more than one entry:
    // - App Names: Might occur multiple times for similar apps (Telegram.app for Desktop vs. Telegram.app for Mac)
    // - Bundle Identifiers: Might occur multiple times for apps in bundles (com.microsoft.word in Word.app and Office bundle)
    //
    // Strategy: Find all entries that point to the given app name. If only one entry comes up, return that. Otherwise, try to match bundle identifiers to narrow it down.
    let name = bundle.fileURL.lastPathComponent.lowercased()
    let possibleEntries = (entriesByName[name] ?? []).filter {
      !$0.requiresBundleIdentifierMatch || $0.bundleIdentifiers.contains(bundle.bundleIdentifier)
    }

    return Self.preferredEntry(from: possibleEntries, for: bundle.bundleIdentifier)
  }

  static func preferredEntry(
    from possibleEntries: [UpdateRepository.Entry], for bundleIdentifier: String
  ) -> UpdateRepository.Entry? {
    guard !possibleEntries.isEmpty else { return nil }
    if possibleEntries.count == 1 {
      return possibleEntries.first
    }

    var matchingIdentifierEntries = [UpdateRepository.Entry]()
    matchingIdentifierEntries.reserveCapacity(possibleEntries.count)
    for entry in possibleEntries where entry.bundleIdentifiers.contains(bundleIdentifier) {
      matchingIdentifierEntries.append(entry)
    }
    if matchingIdentifierEntries.count == 1 {
      return matchingIdentifierEntries.first
    }

    let narrowedEntries =
      matchingIdentifierEntries.isEmpty ? possibleEntries : matchingIdentifierEntries
    var stableEntries = [UpdateRepository.Entry]()
    stableEntries.reserveCapacity(narrowedEntries.count)
    for entry in narrowedEntries where entry.isStableRelease {
      stableEntries.append(entry)
    }
    if stableEntries.count == 1 {
      return stableEntries.first
    }

    return uniqueShortestTokenEntry(in: stableEntries)
  }

  private static func entriesByName(_ entries: [UpdateRepository.Entry]) -> [String:
    [UpdateRepository.Entry]]
  {
    entries.reduce(into: [String: [UpdateRepository.Entry]]()) { entriesByName, entry in
      for name in entry.names {
        entriesByName[name.lowercased(), default: []].append(entry)
      }
    }
  }

  private static func uniqueShortestTokenEntry(in entries: [UpdateRepository.Entry])
    -> UpdateRepository.Entry?
  {
    var shortestEntry: UpdateRepository.Entry?
    var shortestTokenLength: Int?
    var shortestTokenLengthHasTie = false

    for entry in entries {
      let tokenLength = entry.token.count
      guard let currentShortestTokenLength = shortestTokenLength else {
        shortestEntry = entry
        shortestTokenLength = tokenLength
        continue
      }

      if tokenLength == currentShortestTokenLength {
        shortestTokenLengthHasTie = true
      } else if tokenLength < currentShortestTokenLength {
        shortestEntry = entry
        shortestTokenLength = tokenLength
        shortestTokenLengthHasTie = false
      }
    }

    return shortestTokenLengthHasTie ? nil : shortestEntry
  }

}

private final class RemoteDataSource: Sendable {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func load(_ urlType: UpdateRepository.RemoteURL, completion: @escaping @Sendable (Data?) -> Void)
  {
    let cache = UpdateRepositoryCache(
      cacheURL: urlType.cacheURL, userDefaultsKey: urlType.userDefaultsKey)
    if let data = cache.cachedData(), urlType.isValidPayload(data) {
      completion(data)
      return
    }

    guard let url = urlType.url else {
      completion(nil)
      return
    }

    let staleData = cache.cachedData(allowExpired: true).flatMap { data in
      urlType.isValidPayload(data) ? data : nil
    }
    var request = URLRequest(
      url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 20)
    let validators = cache.validators
    if let eTag = validators.eTag {
      request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
    }
    if let lastModified = validators.lastModified {
      request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
    }

    let task = session.dataTask(with: request) { data, response, _ in
      if let response = response as? HTTPURLResponse {
        if response.statusCode == 304, let staleData {
          cache.markFresh()
          completion(staleData)
          return
        }

        if (200..<300).contains(response.statusCode),
          let data,
          urlType.isValidPayload(data)
        {
          cache.store(data, response: response)
          completion(data)
          return
        }
      }

      completion(staleData ?? urlType.fallbackData)
    }
    task.resume()
  }

}

extension Data {
  fileprivate var firstNonWhitespaceByte: UInt8? {
    first { byte in
      switch byte {
      case 0x09, 0x0A, 0x0D, 0x20:
        false
      default:
        true
      }
    }
  }
}
