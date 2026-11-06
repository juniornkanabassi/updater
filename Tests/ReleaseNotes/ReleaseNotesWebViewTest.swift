// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import ScreenCaptureKit
import SwiftUI
import WebKit
import XCTest

@testable import Latest

final class ReleaseNotesWebViewTest: XCTestCase {
  @MainActor
  func testChromeReleaseNotesRenderSecurityEntriesOnSeparateLines() async throws {
    try requireUITests()
    let html = """
      <div class='post'><h2>Stable Channel Update for Desktop</h2>
      <script type='text/template'>
      <p>The Stable channel has been updated to 156.0.8078.73/.74 for Windows and Mac.</p>
      <div><span style="font-weight: 700;">Security Fixes and Rewards</span></div>
      <div><span>
      <span>[N/A][</span><a href="https://issues.chromium.org/issues/571156746"><span style="text-decoration: underline;">571156746</span></a><span>] Critical CVE-2026-118306: Memory corruption in FileSystem. </span><span style="font-style: italic;">Reported by Xinyang Ge on 2026-10-07.</span><b style="font-weight: normal;"><br /></b><span>[TBD][</span><a href="https://issues.chromium.org/issues/572193211"><span style="text-decoration: underline;">572193211</span></a><span>] Critical CVE-2026-118331: Improper input validation in FileAPI. </span><span style="font-style: italic;">Reported by Xinyang Ge on 2026-10-11.</span><b style="font-weight: normal;"><br /></b>
      </span></div>
      </script></div>
      """
    let url = try XCTUnwrap(URL(string: "https://chromereleases.googleblog.com/"))
    let result = await ReleaseNotesMarkup.attributedStringFromChangelogByPreparingOffMain(
      fromHTML: html, baseURL: url, relevantVersion: "156.0.8078.74",
      allowFirstSectionFallback: false)
    let content = try XCTUnwrap(result).get()
    XCTAssertEqual(
      content.string.components(separatedBy: .newlines).filter { !$0.isEmpty },
      [
        "Stable Channel Update for Desktop",
        "The Stable channel has been updated to 156.0.8078.73/.74 for Windows and Mac.",
        "Security Fixes and Rewards",
        "[N/A][571156746] Critical CVE-2026-118306: Memory corruption in FileSystem. Reported by Xinyang Ge on 2026-10-07.",
        "[TBD][572193211] Critical CVE-2026-118331: Improper input validation in FileAPI. Reported by Xinyang Ge on 2026-10-11.",
      ])
    XCTAssertTrue(
      content.runs.contains { $0.text == "Security Fixes and Rewards" && $0.style?.bold == true })
    XCTAssertEqual(
      content.runs.first { $0.text == "571156746" }?.link,
      URL(string: "https://issues.chromium.org/issues/571156746"))
    let app = makeTestApp(name: "Chrome", version: "156.0.8078.74")
    let window = try await makeLatestTestWindow(
      content: ReleaseNotesDetailSurface(app: app, contentState: .text(content)), testCase: self)
    defer { window.close() }
    let host = try XCTUnwrap(window.contentView)
    var renderer: WKWebView?
    let deadline = ContinuousClock.now + .seconds(5)
    repeat {
      host.layoutSubtreeIfNeeded()
      renderer = host.descendant(of: WKWebView.self)
      if renderer != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    } while ContinuousClock.now < deadline
    let web = try XCTUnwrap(renderer, "The production release-note renderer must mount")
    try await waitForWebPaint(web)
    let text =
      try await web.evaluateJavaScript("document.querySelector('main').innerText") as? String
    XCTAssertEqual(text, content.string)
    let bitmap = try await settledWindowBitmap(window)
    let tops =
      try await web.evaluateJavaScript(
        """
        ['Stable Channel', 'Security Fixes', 'Critical CVE-2026-118306', 'Critical CVE-2026-118331'].map(prefix => {
          const nodes = document.createTreeWalker(document.querySelector('main'), NodeFilter.SHOW_TEXT);
          while (nodes.nextNode()) {
            const offset = nodes.currentNode.textContent.indexOf(prefix);
            if (offset < 0) continue;
            const range = document.createRange();
            // Sample visible ink inside the prefix. A range at a newline boundary
            // can include a zero-width rectangle from the preceding line.
            range.setStart(nodes.currentNode, offset + 1); range.setEnd(nodes.currentNode, offset + 2);
            return Array.from(range.getClientRects()).find(rect => rect.width > 0)?.top ?? -1;
          }
          return -1;
        });
        """) as? [Double]
    let positions = try XCTUnwrap(tops)
    XCTAssertEqual(positions.count, 4)
    XCTAssertTrue(positions.allSatisfy { $0 >= 0 })
    for (first, next) in zip(positions, positions.dropFirst()) {
      XCTAssertGreaterThan(
        next - first, 15,
        "Each heading and security entry must start on a new line; positions=\(positions)")
    }
    let attachment = XCTAttachment(
      image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: bitmap.size))
    attachment.name = "chrome-release-notes-blocks"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testReleaseNotesBackgroundDoesNotFlashWhileLoading() async throws {
    try requireUITests()
    let app = makeTestApp(name: "First paint", version: "1")
    for dark in [true, false] {
      let host = NSHostingView(
        rootView: AnyView(Color(nsColor: .textBackgroundColor)))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.contentView = host
      defer { window.close() }
      window.orderFront(nil)
      host.layoutSubtreeIfNeeded()
      try requireWindowServerCapture(window)
      let shareable = try await SCShareableContent.currentProcess
      let capturedWindow = try XCTUnwrap(
        shareable.windows.first { $0.windowID == window.windowNumber })
      let configuration = SCStreamConfiguration()
      configuration.width = 480
      configuration.height = Int(window.frame.height)
      configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
      configuration.pixelFormat = kCVPixelFormatType_32BGRA
      configuration.showsCursor = false
      let frames = ReleaseNotesBackgroundFrames()
      let stream = SCStream(
        filter: SCContentFilter(desktopIndependentWindow: capturedWindow),
        configuration: configuration, delegate: nil)
      try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: .main)
      try await stream.startCapture()
      do {
        for _ in 0..<100 where frames.brightness.isEmpty {
          try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(frames.brightness.isEmpty, "Capture must start before loading the page")
        // Mount fresh renderers after capture starts. Pre-mounting a hidden
        // WebView warms WebKit and misses the actual cold-start transition.
        for index in 0..<6 {
          let text = "Release notes selection \(index)"
          host.rootView = AnyView(
            ReleaseNotesDetailSurface(
              app: app, contentState: .text(ReleaseNotesContent(string: text))
            )
            .id(index / 2))
          host.layoutSubtreeIfNeeded()
          let web = try XCTUnwrap(host.descendant(of: WKWebView.self))
          try await waitForWebContent(web, containing: text)
          try await Task.sleep(for: .milliseconds(100))
        }
        let bitmap = try await settledWindowBitmap(window)
        let attachment = XCTAttachment(
          image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: bitmap.size))
        attachment.name = "release-notes-background-\(dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
        // WebKit's content process can receive appearance changes after the
        // native host. Model that interval explicitly: the page must not paint
        // an opposite-scheme rectangle over the native detail background.
        let web = try XCTUnwrap(host.descendant(of: WKWebView.self))
        _ = try await web.evaluateJavaScript(
          "document.documentElement.style.colorScheme = '\(dark ? "light" : "dark")'")
        _ = try await web.takeSnapshot(configuration: nil)
        try await Task.sleep(for: .milliseconds(100))
        try await stream.stopCapture()
      } catch {
        try? await stream.stopCapture()
        throw error
      }
      XCTAssertGreaterThan(frames.brightness.count, 3, "Capture must include the page transitions")
      if dark {
        XCTAssertLessThan(
          frames.brightness.max() ?? 1, 0.3,
          "The dark release-notes background must never flash white, including its first paint")
      } else {
        XCTAssertGreaterThan(
          frames.brightness.min() ?? 0, 0.85,
          "The light release-notes background must remain light while pages load")
      }
    }
  }

  @MainActor
  func testReleaseNotesTextPreservesRichTextSelectionCopyAndAccessibility() async throws {
    try requireUITests()
    let source = NSMutableAttributedString(string: "Bold link\tbody\nSecond paragraph")
    let fullRange = NSRange(location: 0, length: source.length)
    let linkRange = (source.string as NSString).range(of: "link")
    let originalParagraphStyle = NSMutableParagraphStyle()
    originalParagraphStyle.firstLineHeadIndent = 32
    originalParagraphStyle.headIndent = 24
    originalParagraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: 48)]
    source.addAttributes(
      [
        .font: NSFont.boldSystemFont(ofSize: 22),
        .backgroundColor: NSColor.systemYellow,
        .shadow: NSShadow(),
        .paragraphStyle: originalParagraphStyle,
      ], range: fullRange)
    source.addAttribute(.link, value: URL(string: "https://example.com/release")!, range: linkRange)

    let html = ReleaseNotesWebDocument.html(for: ReleaseNotesLegacyBridge.content(from: source))
    XCTAssertTrue(html.contains("<strong>"))
    XCTAssertFalse(html.contains("background-color"))
    XCTAssertFalse(html.contains("22px"))

    let hostingView = NSHostingView(
      rootView: ReleaseNotesWebView(text: ReleaseNotesLegacyBridge.content(from: source)))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    defer { window.close() }
    window.orderFront(nil)
    hostingView.layoutSubtreeIfNeeded()
    let web = try XCTUnwrap(hostingView.descendant(of: WKWebView.self))
    try await waitForWebContent(web, containing: "Second paragraph")
    let href = try await web.evaluateJavaScript("document.querySelector('a').href") as? String
    XCTAssertEqual(href, "https://example.com/release")
    let selection =
      try await web.evaluateJavaScript(
        """
        var range = document.createRange(); range.selectNodeContents(document.querySelector('main'));
        window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
        window.getSelection().toString();
        """) as? String
    XCTAssertEqual(selection, source.string.replacingOccurrences(of: "\t", with: " "))
    XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
    XCTAssertFalse(web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    XCTAssertFalse(web.allowsBackForwardNavigationGestures)
    XCTAssertFalse(web.allowsMagnification)
  }

  @MainActor
  func testReleaseNotesWebViewReusesRendererAndResetsScrollOnSelection() async throws {
    try requireUITests()
    let firstApp = makeTestApp(name: "First app", version: "1", remoteVersion: "2")
    let secondApp = makeTestApp(name: "Second app", version: "3", remoteVersion: "4")
    let short = ReleaseNotesContent(string: "Short release notes")
    let long = ReleaseNotesContent(
      string: Array(repeating: "Long release notes", count: 150)
        .joined(separator: "\n"))
    let host = NSHostingView(
      rootView: ReleaseNotesDetailSurface(app: firstApp, contentState: .text(long)))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFront(nil)
    host.layoutSubtreeIfNeeded()
    let web = try XCTUnwrap(host.descendant(of: WKWebView.self))
    try await waitForWebContent(web, containing: "Long release notes")
    _ = try await web.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)")
    let scrolled = try await web.evaluateJavaScript("window.scrollY") as? Double
    XCTAssertGreaterThan(scrolled ?? 0, 0)
    _ = try await web.evaluateJavaScript(
      """
      window.rendererReuseMarker = 42;
      var range = document.createRange();
      range.selectNodeContents(document.querySelector('main'));
      window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
      """)
    // Held arrows change the header while the previous notes remain displayed.
    host.rootView = ReleaseNotesDetailSurface(app: secondApp, contentState: .text(long))
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let marker = try await web.evaluateJavaScript("window.rendererReuseMarker") as? Int
    XCTAssertEqual(marker, 42, "Unchanged notes must not reload the page")
    let retainedScroll = try await web.evaluateJavaScript("window.scrollY") as? Double
    XCTAssertEqual(retainedScroll, scrolled, "Header selection must preserve notes scroll position")
    let retainedSelection =
      try await web.evaluateJavaScript("window.getSelection().toString()") as? String
    XCTAssertEqual(retainedSelection, long.string, "Header selection must preserve text selection")
    // A different selection can have identical text. Its new content identity
    // must still reset scroll while the same content object above stays loaded.
    host.rootView = ReleaseNotesDetailSurface(
      app: secondApp, contentState: .text(ReleaseNotesContent(string: long.string)))
    host.layoutSubtreeIfNeeded()
    var reloaded = false
    for _ in 0..<100 {
      reloaded =
        (try await web.evaluateJavaScript("typeof window.rendererReuseMarker === 'undefined'")
          as? Bool) == true
      if reloaded { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(reloaded, "Distinct notes with equal text must reload the page")
    let equalTextScroll = try await web.evaluateJavaScript("window.scrollY") as? Double
    XCTAssertEqual(equalTextScroll, 0)
    host.rootView = ReleaseNotesDetailSurface(app: secondApp, contentState: .loading)
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(host.descendant(of: WKWebView.self) === web)
    host.rootView = ReleaseNotesDetailSurface(app: secondApp, contentState: .text(short))
    window.setContentSize(NSSize(width: 360, height: 280))
    host.layoutSubtreeIfNeeded()
    try await waitForWebContent(web, containing: "Short release notes")
    XCTAssertTrue(host.descendant(of: WKWebView.self) === web)
    let top = try await web.evaluateJavaScript("window.scrollY") as? Double
    XCTAssertEqual(top, 0)
    let overflow =
      try await web.evaluateJavaScript(
        "document.documentElement.scrollWidth > window.innerWidth") as? Bool
    XCTAssertEqual(overflow, false)
  }

  @MainActor
  func testReleaseNotesScrollStopsAtEveryEdgeAndCanReverse() async throws {
    try requireUITests()
    let host = NSHostingView(rootView: ReleaseNotesWebView(text: nil))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFront(nil)

    for lineCount in [1, 80] {
      let content = ReleaseNotesContent(
        string: Array(
          repeating: "Release notes with enough text to wrap onto multiple lines.", count: lineCount
        ).joined(separator: "\n"))
      host.rootView = ReleaseNotesWebView(text: content)
      host.layoutSubtreeIfNeeded()
      let web = try XCTUnwrap(host.descendant(of: WKWebView.self))
      try await waitForWebContent(web, containing: content.string)
      try await waitForWebPaint(web)
      let scrollHeight =
        try await web.evaluateJavaScript(
          "Math.max(0, document.scrollingElement.scrollHeight - window.innerHeight)") as? Double
      let maximum = try XCTUnwrap(scrollHeight)
      XCTAssertEqual(maximum > 0, lineCount > 1)

      for bottom in [false, true] {
        try await positionScroll(web, at: bottom ? maximum : 0)
        for (dx, dy) in [(0, bottom ? -60 : 60), (-60, 0), (60, 0)] {
          let positions = try await scrollGesture(web, dx: Int32(dx), dy: Int32(dy))
          for position in positions {
            XCTAssertEqual(position.x, 0, accuracy: 0.5, "Horizontal overscroll must stay disabled")
            XCTAssertEqual(
              position.y, bottom ? maximum : 0, accuracy: 0.5,
              "Release notes must stay at the edge throughout a gesture (lines=\(lineCount))")
          }
        }
      }
      if maximum > 0 {
        try await positionScroll(web, at: 0)
        let down = try await scrollGesture(web, dx: 0, dy: -30)
        XCTAssertGreaterThan(try XCTUnwrap(down.last).y, 0, "Normal scrolling must still work")
        let up = try await scrollGesture(web, dx: 0, dy: 30)
        XCTAssertLessThan(try XCTUnwrap(up.last).y, try XCTUnwrap(down.last).y)
      }
    }
  }

  @MainActor
  private func positionScroll(_ web: WKWebView, at y: Double) async throws {
    _ = try await web.evaluateJavaScript("window.scrollTo(0, \(y))")
    // Commit the programmatic position before native wheel events use WebKit's
    // asynchronous scrolling tree, which can otherwise retain the old offset.
    try await waitForWebPaint(web)
    let offset = try await web.evaluateJavaScript("window.scrollY") as? Double
    XCTAssertEqual(try XCTUnwrap(offset), y, accuracy: 0.5, "The gesture must start at its target")
  }

  @MainActor
  private func scrollGesture(_ web: WKWebView, dx: Int32, dy: Int32) async throws -> [NSPoint] {
    let window = try XCTUnwrap(web.window)
    let point = window.convertPoint(
      toScreen: web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil))
    let screen = try XCTUnwrap(NSScreen.screens.first)
    var positions: [NSPoint] = []
    // Keep the gesture active while sampling: waiting until it ends would hide
    // rubber-banding because WebKit springs back to its legal scroll range.
    for index in 0..<9 {
      let ended = index == 8
      let event = try XCTUnwrap(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
          wheel1: ended ? 0 : dy, wheel2: ended ? 0 : dx, wheel3: 0))
      event.location = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
      event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      event.setIntegerValueField(
        .scrollWheelEventScrollPhase, value: ended ? 4 : (index == 0 ? 1 : 2))
      web.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
      try await Task.sleep(for: .milliseconds(25))
      let result = try await web.evaluateJavaScript("[window.scrollX, window.scrollY]") as? [Double]
      let offset = try XCTUnwrap(result)
      positions.append(NSPoint(x: offset[0], y: offset[1]))
    }
    try await Task.sleep(for: .milliseconds(300))
    return positions
  }

  @MainActor
  private func waitForWebContent(_ web: WKWebView, containing text: String) async throws {
    let deadline = Date(timeIntervalSinceNow: 10)
    while Date() < deadline {
      if let body = try? await web.evaluateJavaScript("document.body.innerText") as? String,
        body.contains(text), !web.isLoading
      {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("WebKit did not render expected content: \(text)")
  }
}

/// Inspect an empty area below the short notes in actual WindowServer frames.
@MainActor
private final class ReleaseNotesBackgroundFrames: NSObject, SCStreamOutput {
  private(set) var brightness: [Double] = []

  nonisolated func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid,
      let buffer = sampleBuffer.imageBuffer,
      CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
    else { return }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let bytes = CVPixelBufferGetBaseAddress(buffer) else { return }
    let x = CVPixelBufferGetWidth(buffer) / 2
    let y = CVPixelBufferGetHeight(buffer) * 3 / 4
    let pixel = bytes.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4)
      .assumingMemoryBound(to: UInt8.self)
    guard pixel[3] == 255 else { return }
    let value = Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
    // The stream explicitly delivers its samples on the main queue.
    MainActor.assumeIsolated { brightness.append(value) }
  }
}
