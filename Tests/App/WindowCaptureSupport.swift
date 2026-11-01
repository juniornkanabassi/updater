// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import ScreenCaptureKit
import WebKit
import XCTest

@MainActor
func captureWindowBitmap(_ window: NSWindow) async throws -> NSBitmapImageRep {
  let shareable = try await SCShareableContent.currentProcess
  let capturedWindow = try XCTUnwrap(shareable.windows.first { $0.windowID == window.windowNumber })
  let configuration = SCStreamConfiguration()
  configuration.width = Int(window.frame.width * 2)
  configuration.height = Int(window.frame.height * 2)
  configuration.showsCursor = false
  configuration.scalesToFit = true
  let image = try await SCScreenshotManager.captureImage(
    contentFilter: SCContentFilter(desktopIndependentWindow: capturedWindow),
    configuration: configuration)
  return NSBitmapImageRep(cgImage: image)
}

extension NSView {
  func descendant<ViewType: NSView>(of type: ViewType.Type) -> ViewType? {
    if let match = self as? ViewType {
      return match
    }
    return subviews.lazy.compactMap { $0.descendant(of: type) }.first
  }

  func allDescendants() -> [NSView] {
    subviews + subviews.flatMap { $0.allDescendants() }
  }
}

@MainActor
func settledWindowBitmap(_ window: NSWindow) async throws -> NSBitmapImageRep {
  var previous: Data?
  var stableFrames = 0
  for _ in 0..<100 {
    let bitmap = try await captureWindowBitmap(window)
    let pixels = try rgba(bitmap)
    stableFrames = pixels == previous ? stableFrames + 1 : 0
    if stableFrames >= 5 { return bitmap }
    previous = pixels
    try await Task.sleep(for: .milliseconds(50))
  }
  throw CocoaError(.coderInvalidValue)
}
@MainActor
func waitForWebPaint(_ web: WKWebView) async throws {
  var ready = false
  for _ in 0..<200 {
    ready =
      (try? await web.evaluateJavaScript(
        "document.readyState === 'complete' && !!document.querySelector('main')?.textContent.length"
      ) as? Bool) == true && !web.isLoading
    if ready { break }
    try await Task.sleep(for: .milliseconds(50))
  }
  XCTAssertTrue(ready, "Release notes must be loaded before comparing pixels")
  // WebKit suspends animation-frame callbacks in an inactive XCTest host.
  // Snapshotting asks the actual renderer to finish painting without relying
  // on application focus or an unbounded JavaScript promise.
  _ = try await web.takeSnapshot(configuration: nil)
  web.displayIfNeeded()
}
func rgba(_ bitmap: NSBitmapImageRep) throws -> Data {
  let image = try XCTUnwrap(bitmap.cgImage)
  var data = Data(count: bitmap.pixelsWide * bitmap.pixelsHigh * 4)
  try data.withUnsafeMutableBytes { bytes in
    let context = try XCTUnwrap(
      CGContext(
        data: bytes.baseAddress,
        width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bitsPerComponent: 8,
        bytesPerRow: bitmap.pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(
      image, in: CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
  }
  return data
}
