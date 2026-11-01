//
//  ReleaseNotesPipeline.swift
//  Latest
//
//  Created by ertyoii on 18.07.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-07-18.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation

enum ReleaseNotesProvenance: String, Sendable {
  case appStore
  case bundledFallback
  case changelog
  case githubRelease
  case homebrewMetadata
  case remoteURL
  case sparkleEmbedded
  case webKit
}

enum ReleaseNotesQuality: Int, Comparable, Sendable {
  case rejected
  case genericMetadata
  case degraded
  case genuine

  static func < (lhs: ReleaseNotesQuality, rhs: ReleaseNotesQuality) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

struct ResolvedReleaseNotes: Sendable {
  let content: ReleaseNotesContent
  let quality: ReleaseNotesQuality
  let provenance: ReleaseNotesProvenance
}

struct ReleaseNotesContext: Sendable {
  let appName: String
  let bundleIdentifier: String
  let localVersion: String?
  let remoteVersion: String?
  let platform: String

  init(app: App, platform: String = "macOS") {
    appName = app.name
    bundleIdentifier = app.bundleIdentifier
    localVersion = app.version.versionNumber ?? app.version.buildNumber
    remoteVersion = app.releaseNotesVersion.versionNumber ?? app.releaseNotesVersion.buildNumber
    self.platform = platform
  }

  init(
    appName: String,
    bundleIdentifier: String,
    localVersion: String?,
    remoteVersion: String?,
    platform: String = "macOS"
  ) {
    self.appName = appName
    self.bundleIdentifier = bundleIdentifier
    self.localVersion = localVersion
    self.remoteVersion = remoteVersion
    self.platform = platform
  }
}

struct ReleaseNotesCandidate: Sendable {
  let markup: String
  let baseURL: URL?
  let provenance: ReleaseNotesProvenance
  let qualityHint: ReleaseNotesQuality
  let declaredAppIdentifiers: Set<String>
  let declaredVersion: String?
  let declaredPlatforms: Set<String>

  init(
    markup: String,
    baseURL: URL?,
    provenance: ReleaseNotesProvenance,
    qualityHint: ReleaseNotesQuality = .genuine,
    declaredAppIdentifiers: Set<String> = [],
    declaredVersion: String? = nil,
    declaredPlatforms: Set<String> = []
  ) {
    self.markup = markup
    self.baseURL = baseURL
    self.provenance = provenance
    self.qualityHint = qualityHint
    self.declaredAppIdentifiers = declaredAppIdentifiers
    self.declaredVersion = declaredVersion
    self.declaredPlatforms = declaredPlatforms
  }
}

enum ReleaseNotesCandidateRejection: Error, Equatable {
  case empty
  case malformed
  case oversized
  case wrongApplication
  case wrongPlatform
  case wrongVersion
}

struct ReleaseNotesCandidateScorer: Sendable {
  static let maximumMarkupSize = 2 * 1_024 * 1_024

  let maximumMarkupSize: Int

  init(maximumMarkupSize: Int = Self.maximumMarkupSize) {
    self.maximumMarkupSize = maximumMarkupSize
  }

  func quality(
    of candidate: ReleaseNotesCandidate,
    for context: ReleaseNotesContext
  ) throws -> ReleaseNotesQuality {
    let trimmedMarkup = candidate.markup.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMarkup.isEmpty else {
      throw ReleaseNotesCandidateRejection.empty
    }
    guard candidate.markup.utf8.count <= maximumMarkupSize else {
      throw ReleaseNotesCandidateRejection.oversized
    }
    guard !ReleaseNotesMarkup.looksLikeBinaryOrMojibakeText(trimmedMarkup) else {
      throw ReleaseNotesCandidateRejection.malformed
    }

    if !candidate.declaredAppIdentifiers.isEmpty {
      let expected = Self.normalizedIdentifier(context.bundleIdentifier)
      guard
        candidate.declaredAppIdentifiers.contains(where: {
          Self.normalizedIdentifier($0) == expected
        })
      else {
        throw ReleaseNotesCandidateRejection.wrongApplication
      }
    }

    if let declaredVersion = candidate.declaredVersion,
      let remoteVersion = context.remoteVersion,
      !Self.versionsMatch(declaredVersion, remoteVersion)
    {
      throw ReleaseNotesCandidateRejection.wrongVersion
    }

    if !candidate.declaredPlatforms.isEmpty {
      let expectedPlatform = context.platform.lowercased()
      guard
        candidate.declaredPlatforms.contains(where: {
          $0.lowercased() == expectedPlatform
        })
      else {
        throw ReleaseNotesCandidateRejection.wrongPlatform
      }
    }

    return candidate.qualityHint
  }

  private static func normalizedIdentifier(_ value: String) -> String {
    value.lowercased().filter { $0.isLetter || $0.isNumber }
  }

  private static func versionsMatch(_ lhs: String, _ rhs: String) -> Bool {
    let lhs = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
    let rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    return lhs == rhs || lhs.hasPrefix(rhs + ".") || rhs.hasPrefix(lhs + ".")
  }
}

/// Validates and prepares one source. The provider owns ordered fallback between sources.
struct ReleaseNotesPipeline: Sendable {
  private let scorer: ReleaseNotesCandidateScorer

  init(scorer: ReleaseNotesCandidateScorer = ReleaseNotesCandidateScorer()) {
    self.scorer = scorer
  }

  func resolve(
    _ candidate: ReleaseNotesCandidate,
    for context: ReleaseNotesContext
  ) async -> Result<ResolvedReleaseNotes, Error> {
    do {
      let quality = try scorer.quality(of: candidate, for: context)
      let rendered = await ReleaseNotesMarkup.attributedStringByPreparingOffMain(
        from: candidate.markup,
        baseURL: candidate.baseURL,
        relevantVersion: context.remoteVersion
      )
      return rendered.map {
        ResolvedReleaseNotes(
          content: $0, quality: quality, provenance: candidate.provenance)
      }
    } catch {
      return .failure(error)
    }
  }
}

struct ReleaseNotesFetchResponse: Sendable {
  let data: Data
  let response: URLResponse
}

protocol ReleaseNotesHTTPDataLoading: Sendable {
  func load(_ request: URLRequest, maximumResponseSize: Int) async throws
    -> ReleaseNotesFetchResponse
}

struct URLSessionReleaseNotesHTTPDataLoader: ReleaseNotesHTTPDataLoading {
  let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func load(_ request: URLRequest, maximumResponseSize: Int) async throws
    -> ReleaseNotesFetchResponse
  {
    let (bytes, response) = try await session.bytes(for: request)
    if response.expectedContentLength > Int64(maximumResponseSize) {
      throw ReleaseNotesFetchError.oversized
    }

    var data = Data()
    if response.expectedContentLength > 0 {
      data.reserveCapacity(min(Int(response.expectedContentLength), maximumResponseSize))
    }
    for try await byte in bytes {
      guard data.count < maximumResponseSize else {
        throw ReleaseNotesFetchError.oversized
      }
      data.append(byte)
    }
    return ReleaseNotesFetchResponse(data: data, response: response)
  }
}

enum ReleaseNotesFetchError: Error, Equatable {
  case invalidResponse
  case oversized
  case unusableText
}

struct ReleaseNotesFetcher: Sendable {
  private let loader: any ReleaseNotesHTTPDataLoading
  private let maximumResponseSize: Int

  init(
    loader: any ReleaseNotesHTTPDataLoading = URLSessionReleaseNotesHTTPDataLoader(),
    maximumResponseSize: Int = ReleaseNotesCandidateScorer.maximumMarkupSize
  ) {
    self.loader = loader
    self.maximumResponseSize = maximumResponseSize
  }

  func fetchMarkup(
    from url: URL,
    accept: String = "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.9"
  ) async throws -> String {
    guard url.scheme?.lowercased() == "https" else {
      throw ReleaseNotesFetchError.invalidResponse
    }

    var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 6)
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue("Latest", forHTTPHeaderField: "User-Agent")
    let result = try await loader.load(request, maximumResponseSize: maximumResponseSize)

    if let response = result.response as? HTTPURLResponse {
      guard (200..<400).contains(response.statusCode) else {
        throw ReleaseNotesFetchError.invalidResponse
      }
      if response.expectedContentLength > Int64(maximumResponseSize) {
        throw ReleaseNotesFetchError.oversized
      }
    }
    guard result.data.count <= maximumResponseSize else {
      throw ReleaseNotesFetchError.oversized
    }
    if let mimeType = result.response.mimeType?.lowercased(),
      !mimeType.hasPrefix("text/"),
      ![
        "application/atom+xml",
        "application/json",
        "application/rss+xml",
        "application/xhtml+xml",
        "application/xml",
      ].contains(mimeType)
    {
      throw ReleaseNotesFetchError.invalidResponse
    }

    let declaredEncoding = result.response.textEncodingName.flatMap(
      String.Encoding.ianaCharacterSetName)
    let text =
      declaredEncoding.flatMap { String(data: result.data, encoding: $0) } ?? String(
        data: result.data, encoding: .utf8) ?? String(data: result.data, encoding: .isoLatin1)
    guard let text,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !ReleaseNotesMarkup.looksLikeBinaryOrMojibakeText(text)
    else {
      throw ReleaseNotesFetchError.unusableText
    }
    return text
  }
}

extension String.Encoding {
  fileprivate static func ianaCharacterSetName(_ name: String) -> String.Encoding? {
    let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
    guard encoding != kCFStringEncodingInvalidId else { return nil }
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
  }
}

extension App.Update.ReleaseNotes {
  var provenance: ReleaseNotesProvenance {
    switch self {
    case .encoded, .html:
      return .sparkleEmbedded
    case .genericMetadata:
      return .homebrewMetadata
    case .url:
      return .remoteURL
    case .githubRelease:
      return .githubRelease
    case .changelog:
      return .changelog
    }
  }

  var qualityHint: ReleaseNotesQuality {
    if case .genericMetadata = self {
      return .genericMetadata
    }
    return .genuine
  }
}
