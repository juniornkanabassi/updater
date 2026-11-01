//
//  ReleaseNotesMemoryCache.swift
//  Latest
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation

actor ReleaseNotesGitHubCache {
  private struct Entry {
    let data: Data
    let expiresAt: Date
    var lastAccessedAt: Date
  }

  private var entries = [URL: Entry]()
  private var inFlightTasks = [URL: Task<Data, Error>]()
  private var storedBytes = 0
  private let lifetime: TimeInterval = 15 * 60
  private let maximumEntryCount = 128
  private let maximumStoredBytes = 8 * 1_024 * 1_024

  func data(for url: URL, loader: @escaping @Sendable () async throws -> Data) async throws -> Data
  {
    try Task.checkCancellation()
    let now = Date()
    if var entry = entries[url], entry.expiresAt > now {
      entry.lastAccessedAt = now
      entries[url] = entry
      return entry.data
    }
    if let entry = entries.removeValue(forKey: url) {
      storedBytes -= entry.data.count
    }
    if let task = inFlightTasks[url] {
      return try await task.valueUnlessCancelled()
    }

    let task = Task {
      defer { inFlightTasks[url] = nil }
      let data = try await loader()
      let completedAt = Date()
      entries[url] = Entry(
        data: data, expiresAt: completedAt.addingTimeInterval(lifetime),
        lastAccessedAt: completedAt)
      storedBytes += data.count
      evictIfNeeded()
      return data
    }
    inFlightTasks[url] = task
    return try await task.valueUnlessCancelled()
  }

  private func evictIfNeeded() {
    while entries.count > maximumEntryCount || storedBytes > maximumStoredBytes {
      guard let oldest = entries.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt })
      else {
        return
      }
      storedBytes -= oldest.value.data.count
      entries[oldest.key] = nil
    }
  }
}

actor ReleaseNotesHTMLCache {

  private struct Entry {
    let value: Result<String, FetchHTMLError>
    let expiresAt: Date
    var lastAccessedAt: Date
    let cost: Int
  }

  private var entries = [URL: Entry]()
  private var inFlightTasks = [URL: Task<String, Error>]()
  private var storedHTMLBytes = 0
  private let successfulResponseLifetime: TimeInterval = 30 * 60
  private let failedResponseLifetime: TimeInterval = 5 * 60
  private let maximumEntryCount = 128
  private let maximumStoredHTMLBytes = 8 * 1_024 * 1_024

  func html(for url: URL, loader: @escaping @Sendable () async throws -> String) async throws
    -> String
  {
    try Task.checkCancellation()
    let now = Date()
    if var entry = entries[url], entry.expiresAt > now {
      entry.lastAccessedAt = now
      entries[url] = entry
      return try entry.value.get()
    }
    removeEntry(for: url)

    if let task = inFlightTasks[url] {
      return try await task.valueUnlessCancelled()
    }

    let task = Task {
      defer { inFlightTasks[url] = nil }
      do {
        let html = try await loader()
        store(.success(html), for: url, lifetime: successfulResponseLifetime)
        return html
      } catch  where error is CancellationError || (error as? URLError)?.code == .cancelled {
        // Cancellation says nothing about the resource; a later request must be able to retry.
        throw error
      } catch FetchHTMLError.unusableText {
        store(.failure(.unusableText), for: url, lifetime: failedResponseLifetime)
        throw FetchHTMLError.unusableText
      } catch {
        store(.failure(.fetchFailed), for: url, lifetime: failedResponseLifetime)
        throw error
      }
    }
    inFlightTasks[url] = task
    return try await task.valueUnlessCancelled()
  }

  private func store(_ value: Result<String, FetchHTMLError>, for url: URL, lifetime: TimeInterval)
  {
    let now = Date()
    pruneExpiredEntries(at: now)
    removeEntry(for: url)

    let cost = (try? value.get())?.utf8.count ?? 0
    guard cost <= maximumStoredHTMLBytes else { return }
    entries[url] = Entry(
      value: value,
      expiresAt: now.addingTimeInterval(lifetime),
      lastAccessedAt: now,
      cost: cost
    )
    storedHTMLBytes += cost
    trimToLimits()
  }

  private func pruneExpiredEntries(at date: Date) {
    let expiredURLs = entries.compactMap { url, entry in
      entry.expiresAt <= date ? url : nil
    }
    for url in expiredURLs {
      removeEntry(for: url)
    }
  }

  private func trimToLimits() {
    while entries.count > maximumEntryCount || storedHTMLBytes > maximumStoredHTMLBytes {
      guard
        let leastRecentlyUsedURL = entries.min(by: {
          $0.value.lastAccessedAt < $1.value.lastAccessedAt
        })?.key
      else { return }
      removeEntry(for: leastRecentlyUsedURL)
    }
  }

  private func removeEntry(for url: URL) {
    guard let entry = entries.removeValue(forKey: url) else { return }
    storedHTMLBytes -= entry.cost
  }

}
