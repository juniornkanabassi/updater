//
//  ReleaseNotesWebView.swift
//  Latest
//
//  Created by ertyoii on 19.07.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-01.
//  Licensed under GPL-3.0; see LICENSE.md.

import Combine
import SwiftUI
import WebKit

/// SwiftUI owns the page lifetime; WebKit retains native text selection and scrolling.
struct ReleaseNotesWebView: View {
  let text: ReleaseNotesContent?
  @StateObject private var renderer = ReleaseNotesPage()
  @FocusState private var focus: SidebarFocus?
  @Environment(\.windowFocus) private var windowFocus

  var body: some View {
    WebView(renderer.page)
      // The native detail surface owns the background, including before first
      // paint. The HTML body must also stay transparent while appearance syncs.
      .webViewContentBackground(.hidden)
      .focused(windowFocus ?? $focus, equals: .releaseNotes)
      .webViewBackForwardNavigationGestures(.disabled)
      .webViewMagnificationGestures(.disabled)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Release Notes")
      .accessibilityIdentifier("release-notes.web")
      .onAppear { renderer.display(text) }
      .onChange(of: text.map(ObjectIdentifier.init)) { renderer.display(text) }
      .onDisappear { renderer.stop() }
  }
}

@MainActor
private final class ReleaseNotesPage: ObservableObject {
  let page: WebPage
  private var displayedText: ReleaseNotesContent?

  init() {
    var configuration = WebPage.Configuration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultNavigationPreferences.allowsContentJavaScript = false
    page = WebPage(configuration: configuration, navigationDecider: ReleaseNotesNavigationDecider())
  }

  func display(_ text: ReleaseNotesContent?) {
    guard let text, displayedText !== text else { return }
    displayedText = text
    page.load(html: ReleaseNotesWebDocument.html(for: text))
  }

  func stop() {
    page.stopLoading()
    displayedText = nil
  }
}

private struct ReleaseNotesNavigationDecider: WebPage.NavigationDeciding {
  func decidePolicy(
    for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences
  ) async -> WKNavigationActionPolicy {
    if action.navigationType == .linkActivated,
      let url = ReleaseNotesWebDocument.externalURL(action.request.url)
    {
      MacApplicationWorkspace.shared.open(url)
    }
    return action.navigationType == .other && action.request.url?.absoluteString == "about:blank"
      ? .allow : .cancel
  }
}

/// Serializes only the prepared rich text. No vendor scripts, styles, embeds or
/// network resources enter the display web view.
enum ReleaseNotesWebDocument {
  static func html(for text: ReleaseNotesContent) -> String {
    var body = ""
    body.reserveCapacity(text.length)
    for segment in text.runs {
      var run = escape(segment.text, normalizingTabs: true)
      if let style = segment.style {
        if style.bold { run = "<strong>" + run + "</strong>" }
        if style.italic { run = "<em>" + run + "</em>" }
        if style.monospaced { run = "<code>" + run + "</code>" }
        if style.strikethrough { run = "<s>" + run + "</s>" }
      }
      if let url = externalURL(segment.link) {
        run = "<a href=\"" + escape(url.absoluteString) + "\">" + run + "</a>"
      }
      body += run
    }
    return """
      <!doctype html><html><head><meta charset="utf-8">
      <meta name="color-scheme" content="light dark">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
      <style>
      :root { color-scheme: light dark; overscroll-behavior: none; }
      body { margin: 0; padding: \(Int(Space.lg))px \(Int(VisualMetrics.detailHeaderHorizontalPadding))px; font: 13px/1.6 -apple-system, sans-serif;
        color: CanvasText; background: transparent; overflow-wrap: anywhere; }
      main { white-space: pre-wrap; }
      a { color: -apple-system-blue; }
      code { font-family: ui-monospace, monospace; font-size: 12px; }
      </style></head><body><main aria-label="Release Notes">\(body)</main></body></html>
      """
  }

  static func externalURL(_ value: Any?) -> URL? {
    let url: URL?
    switch value {
    case let value as URL: url = value
    case let value as String: url = URL(string: value)
    default: return nil
    }
    guard let url else { return nil }
    switch url.scheme?.lowercased() {
    case "http", "https", "mailto": return url
    default: return nil
    }
  }

  private static func escape(_ string: String, normalizingTabs: Bool = false) -> String {
    var result = ""
    result.reserveCapacity(string.utf8.count)
    for scalar in string.unicodeScalars {
      switch scalar {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "\t" where normalizingTabs: result += " "
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result
  }
}
