//
//  AppStoreUpdateCheckerOperation.swift
//  Latest
//
//  Created by Max Langer on 03.10.19.
//  Copyright © 2019 Max Langer. All rights reserved.
//

import AppKit
import ServiceManagement

private let malformedURLError = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL)

private struct AppStoreLookupCacheKey: Hashable {
  let bundleIdentifier: String
  let countryCode: String
  let entityType: String
}

private enum AppStoreLookupCacheValue {
  case entry(AppStoreEntry)
  case unavailable

  var result: Result<AppStoreEntry, Error> {
    switch self {
    case .entry(let entry):
      return .success(entry)
    case .unavailable:
      return .failure(LatestError.updateInfoUnavailable)
    }
  }
}

private actor AppStoreLookupCache {
  static let shared = AppStoreLookupCache()

  private struct Entry {
    let value: AppStoreLookupCacheValue
    let expiresAt: Date
    var lastAccessedAt: Date
  }

  private struct InFlightLookup {
    let id: UUID
    let task: Task<AppStoreEntry, Error>
  }

  private var values = [AppStoreLookupCacheKey: Entry]()
  private var inFlightTasks = [AppStoreLookupCacheKey: InFlightLookup]()
  private var generation = 0
  private let successfulLookupLifetime: TimeInterval = 15 * 60
  private let unavailableLookupLifetime: TimeInterval = 2 * 60
  private let maximumEntryCount = 512

  func removeAll() {
    generation &+= 1
    values.removeAll(keepingCapacity: true)
    inFlightTasks.values.forEach { $0.task.cancel() }
    inFlightTasks.removeAll(keepingCapacity: true)
  }

  func entry(
    for key: AppStoreLookupCacheKey, loader: @escaping @Sendable () async throws -> AppStoreEntry
  ) async throws -> AppStoreEntry {
    try Task.checkCancellation()
    if let value = cachedValue(for: key, at: Date()) {
      return try value.result.get()
    }

    if let lookup = inFlightTasks[key] {
      return try await lookup.task.valueUnlessCancelled()
    }

    let taskID = UUID()
    let taskGeneration = generation
    let task = Task {
      defer { removeInFlightLookup(for: key, matching: taskID) }
      do {
        let entry = try await loader()
        try Task.checkCancellation()
        if taskGeneration == generation {
          store(.entry(entry), for: key, lifetime: successfulLookupLifetime)
        }
        return entry
      } catch let error as LatestError {
        if taskGeneration == generation, case .updateInfoUnavailable = error {
          store(.unavailable, for: key, lifetime: unavailableLookupLifetime)
        }
        throw error
      }
    }
    inFlightTasks[key] = InFlightLookup(id: taskID, task: task)
    return try await task.valueUnlessCancelled()
  }

  private func removeInFlightLookup(for key: AppStoreLookupCacheKey, matching taskID: UUID) {
    guard inFlightTasks[key]?.id == taskID else { return }
    inFlightTasks[key] = nil
  }

  private func cachedValue(for key: AppStoreLookupCacheKey, at date: Date)
    -> AppStoreLookupCacheValue?
  {
    guard var entry = values[key] else { return nil }
    guard entry.expiresAt > date else {
      values[key] = nil
      return nil
    }
    entry.lastAccessedAt = date
    values[key] = entry
    return entry.value
  }

  private func store(
    _ value: AppStoreLookupCacheValue, for key: AppStoreLookupCacheKey, lifetime: TimeInterval
  ) {
    let now = Date()
    pruneExpiredEntries(at: now)
    values[key] = Entry(
      value: value,
      expiresAt: now.addingTimeInterval(lifetime),
      lastAccessedAt: now
    )

    while values.count > maximumEntryCount {
      guard
        let leastRecentlyUsedKey = values.min(by: {
          $0.value.lastAccessedAt < $1.value.lastAccessedAt
        })?.key
      else { return }
      values[leastRecentlyUsedKey] = nil
    }
  }

  private func pruneExpiredEntries(at date: Date) {
    let expiredKeys = values.compactMap { key, entry in
      entry.expiresAt <= date ? key : nil
    }
    for key in expiredKeys {
      values[key] = nil
    }
  }
}

private final class AppStoreLookupClient: Sendable {
  static let shared = AppStoreLookupClient()

  private let endpoint = URL(string: "https://itunes.apple.com/lookup")
  private let cache = AppStoreLookupCache.shared
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func invalidateCache() async {
    await cache.removeAll()
  }

  func lookup(bundleIdentifiers: [String], entityTypes: [String]) async throws -> AppStoreEntry {
    var lastError: Error = LatestError.updateInfoUnavailable
    for bundleIdentifier in bundleIdentifiers {
      for entityType in entityTypes {
        try Task.checkCancellation()
        do {
          return try await lookup(bundleIdentifier: bundleIdentifier, entityType: entityType)
        } catch  where error is CancellationError || (error as? URLError)?.code == .cancelled {
          throw error
        } catch {
          lastError = error
        }
      }
    }

    throw lastError
  }

  private func lookup(bundleIdentifier: String, entityType: String) async throws -> AppStoreEntry {
    let countryCode = Locale.current.region?.identifier ?? "US"
    let cacheKey = AppStoreLookupCacheKey(
      bundleIdentifier: bundleIdentifier, countryCode: countryCode, entityType: entityType)

    return try await cache.entry(for: cacheKey) {
      guard let endpoint = self.endpoint else {
        throw malformedURLError
      }

      var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
      components?.queryItems = [
        URLQueryItem(name: "limit", value: "1"),
        URLQueryItem(name: "entity", value: entityType),
        URLQueryItem(name: "country", value: countryCode),
        URLQueryItem(name: "bundleId", value: bundleIdentifier),
        // Apple's CDN can retain an older release at the canonical lookup URL.
        // Keep coalescing in our actor cache, but give each HTTP lookup a fresh URL.
        URLQueryItem(name: "t", value: UUID().uuidString),
      ]
      guard let url = components?.url else {
        throw malformedURLError
      }

      let request = URLRequest(
        url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
      let (data, _) = try await self.session.data(for: request)
      guard let entry = try JSONDecoder().decode(EntryList.self, from: data).results.first else {
        throw LatestError.updateInfoUnavailable
      }
      return entry
    }
  }
}

/// Async update checking for a Mac App Store app. The historical type name is
/// retained for API compatibility, but checking is no longer an Operation.
final class AppStoreUpdateCheckerOperation: Sendable {
  static func invalidateLookupCache() async {
    await AppStoreLookupClient.shared.invalidateCache()
  }

  // MARK: - Update Check

  static func canPerformUpdateCheck(forAppAt url: URL) -> Bool {
    // Mac Apps contain a receipt, iOS apps are only available via the Mac App Store
    return AppStoreReceipt.existingURL(forAppAt: url) != nil
  }

  init(with app: App.Bundle, session: URLSession = .shared) {
    self.app = app
    self.lookupClient = AppStoreLookupClient(session: session)
  }

  private let lookupClient: AppStoreLookupClient

  /// The bundle to be checked for updates.
  fileprivate let app: App.Bundle

  func check() async throws -> App.Update {
    guard !app.bundleIdentifier.contains("com.apple.InstallAssistant") else {
      throw LatestError.updateInfoUnavailable
    }
    try Task.checkCancellation()
    let entry = try await fetchAppInfo()
    try Task.checkCancellation()
    return update(from: entry)
  }

  // MARK: - Bundle Operations

  /// Returns whether the app at the given URL is an iOS app wrapped to run on macOS.
  static func isIOSAppBundle(at url: URL) -> Bool {
    // iOS apps are wrapped inside a macOS bundle
    guard let receiptURL = AppStoreReceipt.existingURL(forAppAt: url) else {
      return false
    }

    return AppStoreReceipt.isWrappedIOSReceipt(receiptURL, forAppAt: url)
  }

  /// Returns the App Store lookup entities to try, in priority order.
  static func lookupEntityTypes(forAppAt url: URL) -> [String] {
    return lookupEntityTypes(isIOSAppBundle: isIOSAppBundle(at: url))
  }

  static func lookupEntityTypes(isIOSAppBundle: Bool) -> [String] {
    // Wrapped iOS apps never resolve as native desktop software, so skip the guaranteed miss.
    if isIOSAppBundle {
      return ["macSoftware"]
    }

    return ["desktopSoftware", "macSoftware"]
  }

  static func lookupBundleIdentifiers(for bundleIdentifier: String) -> [String] {
    [bundleIdentifier] + (appStoreBundleIdentifierAliases[bundleIdentifier] ?? [])
  }

  private static let appStoreBundleIdentifierAliases: [String: [String]] = [
    "com.apple.iWork.Keynote": ["com.apple.Keynote"],
    "com.apple.iWork.Numbers": ["com.apple.Numbers"],
    "com.apple.iWork.Pages": ["com.apple.Pages"],
  ]

}

enum AppStoreReceipt {
  static func url(forAppAt appURL: URL) -> URL? {
    if let existingReceiptURL = existingURL(forAppAt: appURL) {
      return existingReceiptURL
    }

    guard appURL.pathExtension == "app" else { return nil }
    return standardReceiptURL(forAppAt: appURL)
  }

  static func existingURL(forAppAt appURL: URL, fileManager: FileManager = .default) -> URL? {
    guard appURL.pathExtension == "app" else { return nil }

    let standardURL = standardReceiptURL(forAppAt: appURL)
    if fileManager.fileExists(atPath: standardURL.path) {
      return standardURL
    }

    return wrappedIOSReceiptURL(forAppAt: appURL, fileManager: fileManager)
  }

  static func standardReceiptURL(forAppAt appURL: URL) -> URL {
    appURL.appendingPathComponent("Contents/_MASReceipt/receipt", isDirectory: false)
  }

  static func isWrappedIOSReceipt(_ receiptURL: URL, forAppAt appURL: URL) -> Bool {
    let wrapperURL = appURL.appendingPathComponent("Contents/Wrapper", isDirectory: true)
      .standardizedFileURL
    let wrapperPath = wrapperURL.path.hasSuffix("/") ? wrapperURL.path : wrapperURL.path + "/"
    return receiptURL.standardizedFileURL.path.hasPrefix(wrapperPath)
  }

  private static func wrappedIOSReceiptURL(forAppAt appURL: URL, fileManager: FileManager) -> URL? {
    let wrapperURL = appURL.appendingPathComponent("Contents/Wrapper", isDirectory: true)
    guard fileManager.fileExists(atPath: wrapperURL.path) else {
      return nil
    }

    guard
      let enumerator = fileManager.enumerator(
        at: wrapperURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }

    for case let url as URL in enumerator {
      guard url.lastPathComponent == "receipt",
        url.deletingLastPathComponent().lastPathComponent == "_MASReceipt"
      else {
        continue
      }

      return url
    }

    return nil
  }
}

extension AppStoreUpdateCheckerOperation {

  /// Returns a proper update object from the given app store entry.
  private func update(from entry: AppStoreEntry) -> App.Update {
    let version = Version(versionNumber: entry.versionNumber, buildNumber: nil)
    let action: App.Update.Action =
      if Self.isIOSAppBundle(at: app.fileURL) {
        // iOS Apps: Open App Store page where the user can update manually. The update operation does not work for them.
        .external(
          label: NSLocalizedString(
            "AppStoreSource", comment: "The source name of apps loaded from the App Store."),
          block: { _ in
            Self.openAppStorePage(for: entry)
          })
      } else {
        // Native capability is stable; updateApp reads the preference when invoked.
        .builtIn(block: { app in
          Self.updateApp(app, entry: entry)
        })

      }

    return App.Update(
      app: self.app, remoteVersion: version, minimumOSVersion: entry.minimumOSVersion,
      source: .appStore, date: entry.date, releaseNotes: entry.releaseNotes, updateAction: action)
  }

  private static func updateApp(_ app: App.Bundle, entry: AppStoreEntry) {
    if AppStoreUpdateSettings.alwaysPerformManualUpdates.active {
      openAppStorePage(for: entry)
      return
    }
    Task { @MainActor in
      UpdateInstallHelperAlert.shared.prepare(
        fallbackURL: entry.pageURL,
        preparation: { try await AppStoreUpdater.prepareForUpdates() }
      ) {
        AppStoreUpdater.enqueueUpdate(for: app, appStoreIdentifier: entry.appStoreIdentifier)
      }
    }
  }

  private static func openAppStorePage(for entry: AppStoreEntry) {
    Task { @MainActor in NSWorkspace.shared.open(entry.pageURL) }
  }

  /// Fetches update info using the App Store lookup entities in priority order.
  private func fetchAppInfo() async throws -> AppStoreEntry {
    // For native Mac apps, prefer `desktopSoftware` because `macSoftware` can return broader Catalyst or iOS metadata. Wrapped iOS apps skip the desktop request above.
    try await lookupClient.lookup(
      bundleIdentifiers: Self.lookupBundleIdentifiers(for: app.bundleIdentifier),
      entityTypes: Self.lookupEntityTypes(forAppAt: app.fileURL)
    )
  }

}

// MARK: - Decoding

/// Object containing a list of App Store entries.
private struct EntryList: Decodable {

  /// The list of entries found while fetching information from the app store.
  let results: [AppStoreEntry]

}

/// Object representing a single entry in fetched information from the app store.
private struct AppStoreEntry: Decodable, Sendable {

  /// The version number of the entry.
  let versionNumber: String

  /// The release notes associated with the entry.
  let releaseNotesContent: String?

  /// The release date of the entry.
  let date: Date?

  /// The link to the app store page.
  let pageURL: URL

  /// The identifier for this app in the App Store context.
  let appStoreIdentifier: UInt64

  /// The minimum OS version required to run this update.
  let minimumOSVersion: OperatingSystemVersion

  // MARK: - Decoding

  enum CodingKeys: String, CodingKey {
    case versionNumber = "version"
    case releaseNotes = "releaseNotes"
    case date = "currentVersionReleaseDate"
    case pageURL = "trackViewUrl"
    case appStoreIdentifier = "trackId"
    case minimumOSVersion = "minimumOsVersion"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.versionNumber = try container.decode(String.self, forKey: .versionNumber)

    let releaseNotes = try container.decodeIfPresent(String.self, forKey: .releaseNotes)
    self.releaseNotesContent = releaseNotes?.replacingOccurrences(
      of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)

    if let date = try container.decodeIfPresent(String.self, forKey: .date) {
      self.date = Self.dateFormatter.date(from: date)
    } else {
      self.date = nil
    }

    let pageURL = try container.decode(String.self, forKey: .pageURL)
    guard let url = URL(string: pageURL.replacingOccurrences(of: "https", with: "macappstore"))
    else {
      throw malformedURLError
    }
    self.pageURL = url

    self.appStoreIdentifier = try container.decode(UInt64.self, forKey: .appStoreIdentifier)

    let osVersionString = try container.decode(String.self, forKey: .minimumOSVersion)
    self.minimumOSVersion = try OperatingSystemVersion(string: osVersionString)
  }

  // MARK: - Utilities

  // The release notes object derived from fetched texts.
  var releaseNotes: App.Update.ReleaseNotes? {
    if let releaseNotesContent = releaseNotesContent {
      return .html(string: releaseNotesContent)
    }

    return nil
  }

  private static let dateFormatter: DateFormatter = {
    // Setup date formatter
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US")

    // Example of the date format: Mon, 28 Nov 2016 14:00:00 +0100
    // This is problematic, because some developers use other date formats
    dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"

    return dateFormatter
  }()

}
