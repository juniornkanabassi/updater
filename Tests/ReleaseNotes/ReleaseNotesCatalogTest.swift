//
//  ReleaseNotesCatalogTest.swift
//  Latest Tests
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import CryptoKit
import XCTest

@testable import Latest

final class ReleaseNotesCatalogTest: XCTestCase {
  func testReleaseNotesSourceCatalogUsesBetterDisplayGitHubReleaseAPI() throws {
    let bundle = App.Bundle(
      version: Version(versionNumber: "4.3.3", buildNumber: "50020"),
      name: "BetterDisplay",
      bundleIdentifier: "pro.betterdisplay.BetterDisplay",
      fileURL: URL(fileURLWithPath: "/Applications/BetterDisplay.app", isDirectory: true),
      source: .sparkle
    )

    for (version, expectedURL, hasFallback) in [
      ("4.3.4", "https://api.github.com/repos/waydabber/BetterDisplay/releases/tags/v4.3.4", true),
      ("4.3.5", "https://api.github.com/repos/waydabber/BetterDisplay/releases/tags/v4.3.5", false),
    ] {
      guard
        case .githubRelease(let apiURL, let fallbackHTML) = ReleaseNotesSourceCatalog.releaseNotes(
          for: bundle, remoteVersion: Version(versionNumber: version, buildNumber: nil))
      else { return XCTFail("Expected BetterDisplay \(version) GitHub release API") }
      XCTAssertEqual(apiURL.absoluteString, expectedURL)
      if hasFallback {
        XCTAssertTrue(fallbackHTML?.contains("BetterDisplay 4.3.4") == true)
      } else {
        XCTAssertNil(fallbackHTML)
      }
    }
  }

  func testReleaseNotesSourceCatalogNormalizesBetterDisplaySparkleReleaseNotesLink() throws {
    let bundle = App.Bundle(
      version: Version(versionNumber: "4.3.3", buildNumber: "50020"),
      name: "BetterDisplay",
      bundleIdentifier: "pro.betterdisplay.BetterDisplay",
      fileURL: URL(fileURLWithPath: "/Applications/BetterDisplay.app", isDirectory: true),
      source: .sparkle
    )

    guard
      case .githubRelease(let apiURL, let fallbackHTML) = ReleaseNotesSourceCatalog.releaseNotes(
        forSparkleReleaseNotesURL: URL(
          string: "https://waydabber.github.io/BetterDisplay/changelog.html?tag=v4.3.4")!,
        bundle: bundle,
        remoteVersion: Version(versionNumber: "4.3.4", buildNumber: "50021")
      )
    else {
      return XCTFail("Expected BetterDisplay appcast link to resolve to its backing GitHub release")
    }

    XCTAssertEqual(
      apiURL.absoluteString,
      "https://api.github.com/repos/waydabber/BetterDisplay/releases/tags/v4.3.4")
    XCTAssertTrue(fallbackHTML?.contains("BetterDisplay 4.3.4") == true)
  }

  func testReleaseNotesSourceCatalogUsesTelegramDesktopChangelog() throws {
    let json = """
      {
      \t"token": "telegram-desktop",
      \t"version": "6.9.2",
      \t"name": ["Telegram"],
      \t"homepage": "https://desktop.telegram.org/",
      \t"url": "https://updates.tdesktop.com/tmac/tsetup.6.9.2.dmg",
      \t"artifacts": [
      \t\t{
      \t\t\t"app": ["Telegram.app"]
      \t\t}
      \t],
      \t"depends_on": {
      \t\t"macos": {}
      \t}
      }
      """
    let entry = try JSONDecoder().decode(UpdateRepository.Entry.self, from: Data(json.utf8))

    guard
      case .changelog(let urls, let versionPrefix, let allowsLatestFallback, let fallbackHTML) =
        entry.releaseNotes
    else {
      return XCTFail("Expected Telegram Desktop changelog")
    }

    XCTAssertEqual(
      urls.map(\.absoluteString),
      ["https://raw.githubusercontent.com/telegramdesktop/tdesktop/dev/changelog.txt"])
    XCTAssertEqual(versionPrefix, "6.9.2")
    XCTAssertFalse(allowsLatestFallback)
    XCTAssertNil(fallbackHTML)
  }

  func testReleaseNotesSourceCatalogUsesDockerDesktopMarkdownSource() throws {
    let json = """
      {
      \t"token": "docker-desktop",
      \t"version": "4.77.0,228796",
      \t"name": ["Docker"],
      \t"homepage": "https://www.docker.com/products/docker-desktop/",
      \t"url": "https://desktop.docker.com/mac/main/arm64/228796/Docker.dmg",
      \t"artifacts": [
      \t\t{
      \t\t\t"app": ["Docker.app"]
      \t\t}
      \t],
      \t"depends_on": {
      \t\t"macos": {}
      \t}
      }
      """
    let entry = try JSONDecoder().decode(UpdateRepository.Entry.self, from: Data(json.utf8))

    guard
      case .changelog(let urls, let versionPrefix, let allowsLatestFallback, let fallbackHTML) =
        entry.releaseNotes
    else {
      return XCTFail("Expected Docker Desktop changelog release notes")
    }

    XCTAssertEqual(urls, [URL(string: "https://docs.docker.com/desktop/release-notes.md")!])
    XCTAssertEqual(versionPrefix, "4.77.0")
    XCTAssertFalse(allowsLatestFallback)
    XCTAssertNil(fallbackHTML)
  }

  func testReleaseNotesSourceCatalogUsesChromeReleaseBlog() throws {
    let json = """
      {
      \t"token": "google-chrome",
      \t"version": "149.0.7827.115",
      \t"name": ["Google Chrome"],
      \t"homepage": "https://www.google.com/chrome/",
      \t"url": "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
      \t"artifacts": [
      \t\t{
      \t\t\t"app": ["Google Chrome.app"]
      \t\t}
      \t],
      \t"depends_on": {
      \t\t"macos": {}
      \t}
      }
      """
    let entry = try JSONDecoder().decode(UpdateRepository.Entry.self, from: Data(json.utf8))

    guard
      case .changelog(let urls, let versionPrefix, let allowsLatestFallback, let fallbackHTML) =
        entry.releaseNotes
    else {
      return XCTFail("Expected Chrome release blog notes")
    }

    XCTAssertEqual(urls, [URL(string: "https://chromereleases.googleblog.com/")!])
    XCTAssertEqual(versionPrefix, "149.0.7827.115")
    XCTAssertFalse(allowsLatestFallback)
    XCTAssertNil(fallbackHTML)
  }

  func testReleaseNotesSourceCatalogDoesNotUseNotionProductReleases() {
    let releaseNotes = ReleaseNotesSourceCatalog.releaseNotes(
      forHomebrewToken: "notion",
      version: Version(versionNumber: "7.21.0", buildNumber: nil)
    )

    XCTAssertNil(releaseNotes)
  }

  func testReleaseNotesSourceCatalogUsesBrunoGitHubReleaseForBundle() throws {
    let bundle = App.Bundle(
      version: Version(versionNumber: "3.4.1", buildNumber: nil),
      name: "Bruno",
      bundleIdentifier: "com.usebruno.app",
      fileURL: URL(fileURLWithPath: "/Applications/Bruno.app", isDirectory: true),
      source: .sparkle
    )

    guard
      case .githubRelease(let apiURL, let fallbackHTML) = ReleaseNotesSourceCatalog.releaseNotes(
        for: bundle,
        remoteVersion: Version(versionNumber: "3.4.2", buildNumber: nil)
      )
    else {
      return XCTFail("Expected Bruno GitHub release notes")
    }

    XCTAssertEqual(
      apiURL.absoluteString, "https://api.github.com/repos/usebruno/bruno/releases/tags/v3.4.2")
    XCTAssertNil(fallbackHTML)
  }

  func testElectronReleaseNotesSourceReadsGitHubProviderConfiguration() {
    let configuration = """
      provider: github
      owner: example-org
      repo: example-app
      updaterCacheDirName: example-updater
      """

    XCTAssertEqual(
      ElectronReleaseNotesSource.githubReleaseAPIURL(from: configuration)?.absoluteString,
      "https://api.github.com/repos/example-org/example-app/releases/latest"
    )
    XCTAssertNil(
      ElectronReleaseNotesSource.githubReleaseAPIURL(
        from: "provider: generic\nurl: https://updates.example.com"
      )
    )
  }

  func testReleaseNotesSourceCatalogUsesBundledElectronUpdaterConfiguration() throws {
    let appURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("Electron-\(UUID().uuidString).app", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: appURL) }

    let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    let configuration = "provider: github\nowner: example-org\nrepo: desktop-client\n"
    try Data(configuration.utf8).write(to: resourcesURL.appendingPathComponent("app-update.yml"))

    let bundle = App.Bundle(
      version: Version(versionNumber: "1.0", buildNumber: nil),
      name: "Uncatalogued Electron App",
      bundleIdentifier: "com.example.uncatalogued-electron",
      fileURL: appURL,
      source: .none
    )
    let remoteVersion = Version(versionNumber: "2.0", buildNumber: nil)

    guard
      case .githubRelease(let apiURL, let fallbackHTML) = ReleaseNotesSourceCatalog.releaseNotes(
        for: bundle,
        remoteVersion: remoteVersion
      )
    else {
      return XCTFail("Expected Electron GitHub release notes")
    }

    XCTAssertEqual(
      apiURL.absoluteString,
      "https://api.github.com/repos/example-org/desktop-client/releases/latest")
    XCTAssertNil(fallbackHTML)
  }

  func testReleaseNotesSourceCatalogCoversPopularNonGitHubApps() throws {
    let version = Version(versionNumber: "4.46.96", buildNumber: nil)
    let expectedURLs = [
      "microsoft-edge":
        "https://learn.microsoft.com/en-us/deployedge/microsoft-edge-relnote-stable-channel",
      "raycast": "https://www.raycast.com/changelog",
      "slack": "https://slack.com/release-notes/mac",
      "warp": "https://docs.warp.dev/changelog",
    ]

    for (token, expectedURL) in expectedURLs {
      guard
        case .changelog(let urls, let versionPrefix, _, _) = ReleaseNotesSourceCatalog.releaseNotes(
          forHomebrewToken: token,
          version: version
        )
      else {
        return XCTFail("Expected catalog changelog for \(token)")
      }
      XCTAssertEqual(urls.map(\.absoluteString), [expectedURL])
      XCTAssertEqual(versionPrefix, "4.46.96")
    }
  }

  func testNewSourcesMatchPublishedVersionPrecision() throws {
    for (token, version, prefix) in [
      ("expressvpn", "14.2.1.13658", "14.2.1"), ("navicat-for-postgresql", "17.3.12", "17.3.12"),
      ("navicat-for-sqlite", "17.3.12", "17.3.12"),
    ] {
      guard
        case .changelog(let urls, let actualPrefix, let latestFallback, _) =
          ReleaseNotesSourceCatalog.releaseNotes(
            forHomebrewToken: token, version: Version(versionNumber: version, buildNumber: nil))
      else { return XCTFail("Missing source for \(token)") }
      XCTAssertEqual(actualPrefix, prefix)
      XCTAssertEqual(urls.count, 1)
      XCTAssertFalse(latestFallback)
    }
  }

  func testEveryCatalogHomebrewTokenProducesAConcreteRoute() {
    let version = Version(versionNumber: "2026.1.4", buildNumber: "261.26222.59")
    let tokens = ReleaseNotesSourceCatalog.catalogHomebrewTokens

    XCTAssertGreaterThanOrEqual(tokens.count, 115)
    for token in tokens {
      XCTAssertNotNil(
        ReleaseNotesSourceCatalog.releaseNotes(
          forHomebrewToken: token,
          version: version
        ),
        "Missing release-note route for \(token)"
      )
    }
  }

  func testReleaseNotesSourceCatalogExpandsMajorVersionAndNewVendorRoutes() throws {
    let expectations: [(String, String, String)] = [
      ("ableton-live-suite", "12.4.3", "https://www.ableton.com/en/release-notes/live-12/"),
      ("dcp-o-matic-player", "2.18.45", "https://www.dcpomatic.com/release-notes?v=2.18.45"),
      ("moom", "4.5.1", "https://manytricks.com/moom/releasenotes/"),
      ("little-snitch@5", "5.8", "https://www.obdev.at/products/littlesnitch/releasenotes5.html"),
      (
        "a-better-finder-rename", "12.31",
        "https://www.publicspace.net/ABetterFinderRename/version.html"
      ),
    ]

    for (token, version, expectedURL) in expectations {
      guard
        case .changelog(let urls, let versionPrefix, _, _) = ReleaseNotesSourceCatalog.releaseNotes(
          forHomebrewToken: token,
          version: Version(versionNumber: version, buildNumber: nil)
        )
      else {
        return XCTFail("Expected catalog changelog for \(token)")
      }
      XCTAssertEqual(urls.map(\.absoluteString), [expectedURL])
      XCTAssertEqual(versionPrefix, version)
    }
  }

  func testReleaseNotesSourceCatalogUsesVerifiedVendorReleaseNotePages() throws {
    let expectations: [(String, String, String)] = [
      ("sidenotes", "1.6.3", "https://www.apptorium.com/sidenotes/release-notes/1.6.3"),
      (
        "elgato-wave-link", "3.2.2",
        "https://help.elgato.com/hc/en-us/sections/4913442828941-Wave-Link-Release-Notesverf%C3%BCgbar"
      ),
      ("app-cleaner", "9.2.4", "https://nektony.com/mac-app-cleaner/download"),
      ("disk-expert", "6.0.2", "https://nektony.com/disk-expert/download"),
      ("duplicate-file-finder", "9.2.1", "https://nektony.com/duplicate-finder-free/download"),
      ("memory-cleaner", "5.5.3", "https://nektony.com/memory-cleaner/download"),
      (
        "navicat-premium", "17.3.12",
        "https://www.navicat.com/en/products/navicat-premium-release-note"
      ),
      (
        "navicat-for-mysql", "17.3.12",
        "https://www.navicat.com/en/products/navicat-for-mysql-release-note"
      ),
      ("teacode", "1.1.3", "https://www.apptorium.com/teacode/release-notes/1.1.3"),
      ("workspaces", "2.1.5", "https://www.apptorium.com/workspaces/release-notes/2.1.5"),
      ("windowkeys", "3.0.1", "https://www.apptorium.com/windowkeys/release-notes/3.0.1"),
      ("expressions", "1.3.9", "https://www.apptorium.com/expressions/release-notes/1.3.9"),
      ("screenfocus", "1.1.1", "https://www.apptorium.com/screenfocus/release-notes/1.1.1"),
      (
        "eclipse-java", "4.40",
        "https://raw.githubusercontent.com/eclipse-platform/www.eclipse.org-eclipse/master/news/4.40/platform.md"
      ),
      ("parallels", "26.4.0", "https://kb.parallels.com/en/131014"),
    ]

    for (token, version, expectedURL) in expectations {
      guard
        case .changelog(let urls, let versionPrefix, _, _) = ReleaseNotesSourceCatalog.releaseNotes(
          forHomebrewToken: token,
          version: Version(versionNumber: version, buildNumber: nil)
        )
      else {
        return XCTFail("Expected catalog changelog for \(token)")
      }
      XCTAssertEqual(urls.map(\.absoluteString), [expectedURL])
      XCTAssertEqual(versionPrefix, version)
    }
  }

  func testReleaseNotesSourceCatalogUsesGhosttySourceMarkdown() throws {
    guard
      case .changelog(let urls, let versionPrefix, let allowsLatestFallback, _) =
        ReleaseNotesSourceCatalog.releaseNotes(
          forHomebrewToken: "ghostty",
          version: Version(versionNumber: "1.3.1", buildNumber: nil)
        )
    else {
      return XCTFail("Expected Ghostty changelog release notes")
    }

    XCTAssertEqual(
      urls,
      [
        URL(
          string:
            "https://raw.githubusercontent.com/ghostty-org/website/main/docs/install/release-notes/1-3-1.mdx"
        )!
      ])
    XCTAssertEqual(versionPrefix, "1.3.1")
    XCTAssertFalse(allowsLatestFallback)
  }

  func testReleaseNotesSourceCatalogUsesObsidianChangelog() throws {
    guard
      case .changelog(let urls, let versionPrefix, let allowsLatestFallback, let fallbackHTML) =
        ReleaseNotesSourceCatalog.releaseNotes(
          forHomebrewToken: "obsidian",
          version: Version(versionNumber: "1.12.7", buildNumber: nil)
        )
    else {
      return XCTFail("Expected Obsidian changelog release notes")
    }

    XCTAssertEqual(urls, [URL(string: "https://obsidian.md/changelog/")!])
    XCTAssertEqual(versionPrefix, "1.12.7")
    XCTAssertFalse(allowsLatestFallback)
    XCTAssertNil(fallbackHTML)
  }

  func testReleaseNotesSourceCatalogUsesVersionedJetBrainsWhatsNewPage() throws {
    guard
      case .changelog(let urls, let versionPrefix, let allowsLatestFallback, _) =
        ReleaseNotesSourceCatalog.releaseNotes(
          forHomebrewToken: "intellij-idea",
          version: Version(versionNumber: "2026.1.4", buildNumber: "261.26222.65")
        )
    else {
      return XCTFail("Expected JetBrains What's New release notes")
    }

    XCTAssertEqual(urls, [URL(string: "https://www.jetbrains.com/idea/whatsnew/2026-1/")!])
    XCTAssertEqual(versionPrefix, "2026.1")
    XCTAssertFalse(allowsLatestFallback)
  }

  func testReleaseNotesSourceCatalogUsesRogueAmoebaProductHistory() throws {
    guard
      case .changelog(let urls, let versionPrefix, let allowsLatestFallback, _) =
        ReleaseNotesSourceCatalog.releaseNotes(
          forHomebrewToken: "audio-hijack",
          version: Version(versionNumber: "4.5.9", buildNumber: nil)
        )
    else {
      return XCTFail("Expected Rogue Amoeba release notes")
    }

    XCTAssertEqual(urls.first?.host, "rogueamoeba.com")
    XCTAssertEqual(
      URLComponents(url: try XCTUnwrap(urls.first), resolvingAgainstBaseURL: false)?.queryItems?
        .first?.value, "Audio Hijack")
    XCTAssertEqual(versionPrefix, "4.5.9")
    XCTAssertFalse(allowsLatestFallback)
  }

}
