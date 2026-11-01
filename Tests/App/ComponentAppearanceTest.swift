// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import WebKit
import XCTest

@testable import Latest

final class ComponentAppearanceTest: XCTestCase {
  @MainActor
  func testDetailAndLocationsMatchReviewedAppearance() async throws {
    try requireUITests()
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else {
      throw XCTSkip("Visual baselines are scoped to the macOS 26 appearance.")
    }

    for scenario in AppearanceFixtureScenario.regressionCases {
      // Keep capture outside XCTContext activities: Xcode 26.6 on the hosted
      // runner can fail activity teardown with InvalidTransition (idle ->
      // failed(deinit)). Assertions and attachments already name the scenario.
      let rendered = try await AppearanceFixtureRenderer.render(scenario)
      try AppearanceFixtureRenderer.assertMatchesBaseline(
        rendered, scenario: scenario, testCase: self)
    }
  }
}

@MainActor
private enum AppearanceFixtureRenderer {
  /// Recording writes candidates to /tmp for review; it never changes the
  /// checked-in reference images or skips their comparison.
  private static let candidateOutputDirectory: URL? = {
    guard
      ProcessInfo.processInfo.environment["LATEST_RECORD_VISUAL_BASELINES"] == "1"
        || FileManager.default.fileExists(atPath: "/tmp/latest-record-visual-baselines")
    else {
      return nil
    }
    return URL(fileURLWithPath: "/tmp/latest-visual-candidates", isDirectory: true)
  }()
  private static let diagnosticOutputDirectory: URL? = {
    if let path = ProcessInfo.processInfo.environment["LATEST_VISUAL_OUTPUT_DIRECTORY"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    let fallbackPath = "/tmp/latest-visual-output"
    guard FileManager.default.fileExists(atPath: fallbackPath) else { return nil }
    return URL(fileURLWithPath: fallbackPath, isDirectory: true)
  }()
  private static let baselineDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("VisualBaselines", isDirectory: true)
    .appendingPathComponent("macos-26", isDirectory: true)

  static func render(_ scenario: AppearanceFixtureScenario) async throws -> NSBitmapImageRep {
    let rootView = AppearanceFixtureView(scenario: scenario)
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = CGRect(origin: .zero, size: scenario.size)

    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: scenario.size),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(
      named: scenario.colorScheme == .dark ? .darkAqua : .aqua
    )
    window.contentView = hostingView
    defer { window.close() }
    window.layoutIfNeeded()
    hostingView.layoutSubtreeIfNeeded()
    if case .detail(.releaseNotes) = scenario.surface {
      var ready = false
      for _ in 0..<200 {
        if let web = hostingView.descendant(of: WKWebView.self), !web.isLoading,
          let body = try? await web.evaluateJavaScript("document.body.innerText") as? String,
          body.contains("Improvements to Cursor")
        {
          _ = try await web.takeSnapshot(configuration: nil)
          ready = true
          break
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      guard ready else { throw VisualRegressionError.didNotSettle(scenario.id + " WebKit") }
    }
    // Suspend the main actor so SwiftUI .task work (including the header icon)
    // can run. Pumping RunLoop from a synchronous test does not provide that
    // scheduling boundary. Require consecutive settled frames, not one timed
    // screenshot, and fail rather than silently recording an unsettled view.
    var previousPixels: [UInt8]?
    var stableFrames = 0
    for _ in 0..<100 {
      try await Task.sleep(for: .milliseconds(50))
      window.layoutIfNeeded()
      hostingView.layoutSubtreeIfNeeded()
      let bitmap = try capture(hostingView, size: scenario.size)
      let pixels = try rgbaBytes(from: bitmap)
      stableFrames = pixels == previousPixels ? stableFrames + 1 : 0
      if stableFrames >= 5 { return bitmap }
      previousPixels = pixels
    }
    throw VisualRegressionError.didNotSettle(scenario.id)
  }

  private static func capture(_ hostingView: NSView, size: CGSize) throws -> NSBitmapImageRep {

    // References are Retina captures. Hosted runners have a 1x display,
    // so allocate the reference scale independently of the attached screen.
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * 2),
        pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else {
      throw VisualRegressionError.couldNotCreateBitmap
    }
    bitmap.size = size
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    return bitmap
  }

  static func assertMatchesBaseline(
    _ rendered: NSBitmapImageRep,
    scenario: AppearanceFixtureScenario,
    testCase: XCTestCase
  ) throws {
    let baselineURL = baselineDirectory.appendingPathComponent(baselineFilename(for: scenario))
    guard let png = rendered.representation(using: .png, properties: [:]) else {
      throw VisualRegressionError.couldNotEncodePNG
    }
    if let diagnosticOutputDirectory {
      try FileManager.default.createDirectory(
        at: diagnosticOutputDirectory,
        withIntermediateDirectories: true
      )
      try png.write(
        to: diagnosticOutputDirectory.appendingPathComponent("\(scenario.id)-actual.png"),
        options: .atomic
      )
    }

    if let candidateOutputDirectory {
      try FileManager.default.createDirectory(
        at: candidateOutputDirectory,
        withIntermediateDirectories: true
      )
      try png.write(
        to: candidateOutputDirectory.appendingPathComponent("\(scenario.id).png"),
        options: .atomic
      )
    }

    guard let baselineData = try? Data(contentsOf: baselineURL),
      let baseline = NSBitmapImageRep(data: baselineData)
    else {
      XCTFail("Missing checked-in visual reference \(baselineURL.path)")
      return
    }

    let comparison = try compare(
      baseline: baseline,
      actual: rendered,
      regions: comparisonRegions(for: scenario)
    )
    guard !comparison.passed else { return }
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "\(scenario.id)-actual"
    attachment.lifetime = .keepAlways
    testCase.add(attachment)
    XCTFail(
      String(
        format:
          "Visual regression in %@: %.3f%% pixels exceeded tolerance, RMS %.3f (limits %.3f%% / %.3f)",
        scenario.id,
        comparison.changedFraction * 100,
        comparison.rms,
        comparison.changedFractionLimit * 100,
        comparison.rmsLimit
      )
    )
  }

  private static func baselineFilename(for scenario: AppearanceFixtureScenario) -> String {
    return "\(scenario.id).png"
  }

  private static func comparisonRegions(for scenario: AppearanceFixtureScenario) -> [CGRect] {
    let insetBounds = CGRect(origin: .zero, size: scenario.size).insetBy(dx: 2, dy: 2)
    switch scenario.surface {
    case .detail:
      let leftToRightDetail = AppearanceFixtureMetrics.detailFrame(in: scenario.size)
      let detail =
        scenario.layoutDirection == .rightToLeft
        ? CGRect(origin: .zero, size: leftToRightDetail.size)
        : leftToRightDetail
      // Only the real detail surface is covered by these existing references.
      // NSWorkspace owns the generic document icon and can change its shadow
      // pixels independently of Latest. Compare the production-owned metadata
      // and action portion of the header.
      let headerContentStart =
        detail.minX
        + VisualMetrics.detailHeaderHorizontalPadding
        + VisualMetrics.detailIconSize
        + 5
      let header = CGRect(
        x: headerContentStart,
        y: 2,
        width: max(0, detail.maxX - headerContentStart - 2),
        height: AppearanceFixtureMetrics.detailHeaderHeight - 2
      )
      let body = CGRect(
        x: detail.minX + 2,
        y: AppearanceFixtureMetrics.detailHeaderHeight,
        width: max(0, detail.width - 4),
        height: max(0, detail.height - AppearanceFixtureMetrics.detailHeaderHeight - 4)
      )
      return [header, body]
    case .locations:
      return [insetBounds]
    }
  }

  private static func compare(
    baseline: NSBitmapImageRep,
    actual: NSBitmapImageRep,
    regions: [CGRect]
  ) throws -> VisualComparison {
    guard baseline.pixelsWide == actual.pixelsWide,
      baseline.pixelsHigh == actual.pixelsHigh
    else {
      throw VisualRegressionError.dimensionMismatch(
        expected: CGSize(width: baseline.pixelsWide, height: baseline.pixelsHigh),
        actual: CGSize(width: actual.pixelsWide, height: actual.pixelsHigh)
      )
    }

    let expected = try rgbaBytes(from: baseline)
    let observed = try rgbaBytes(from: actual)
    let scaleX = CGFloat(actual.pixelsWide) / actual.size.width
    let scaleY = CGFloat(actual.pixelsHigh) / actual.size.height
    let channelTolerance = 12
    var comparedPixels = 0
    var changedPixels = 0
    var squaredError = 0.0

    for region in regions {
      let pixelRegion = CGRect(
        x: region.minX * scaleX,
        y: region.minY * scaleY,
        width: region.width * scaleX,
        height: region.height * scaleY
      ).integral
      let minX = max(0, Int(pixelRegion.minX))
      let maxX = min(actual.pixelsWide, Int(pixelRegion.maxX))
      let minY = max(0, Int(pixelRegion.minY))
      let maxY = min(actual.pixelsHigh, Int(pixelRegion.maxY))

      for y in minY..<maxY {
        for x in minX..<maxX {
          let offset = ((y * actual.pixelsWide) + x) * 4
          var pixelChanged = false
          for channel in 0..<3 {
            let delta = abs(Int(expected[offset + channel]) - Int(observed[offset + channel]))
            pixelChanged = pixelChanged || delta > channelTolerance
            squaredError += Double(delta * delta)
          }
          comparedPixels += 1
          if pixelChanged {
            changedPixels += 1
          }
        }
      }
    }

    let changedFraction = comparedPixels == 0 ? 0 : Double(changedPixels) / Double(comparedPixels)
    let rms = comparedPixels == 0 ? 0 : sqrt(squaredError / Double(comparedPixels * 3))
    let changedFractionLimit = 0.0025
    let rmsLimit = 1.5
    return VisualComparison(
      passed: changedFraction <= changedFractionLimit && rms <= rmsLimit,
      changedFraction: changedFraction,
      rms: rms,
      changedFractionLimit: changedFractionLimit,
      rmsLimit: rmsLimit
    )
  }

  private static func rgbaBytes(from bitmap: NSBitmapImageRep) throws -> [UInt8] {
    guard let image = bitmap.cgImage else {
      throw VisualRegressionError.couldNotReadPixels
    }
    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw VisualRegressionError.couldNotReadPixels
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return bytes
  }
}

private struct VisualComparison {
  let passed: Bool
  let changedFraction: Double
  let rms: Double
  let changedFractionLimit: Double
  let rmsLimit: Double
}

private enum VisualRegressionError: LocalizedError {
  case didNotSettle(String)
  case couldNotCreateBitmap
  case couldNotEncodePNG
  case couldNotReadPixels
  case dimensionMismatch(expected: CGSize, actual: CGSize)

  var errorDescription: String? {
    switch self {
    case .didNotSettle(let scenario):
      "Visual fixture did not settle: \(scenario)"
    case .couldNotCreateBitmap:
      "Could not create a bitmap for the appearance fixture."
    case .couldNotEncodePNG:
      "Could not encode the appearance fixture as PNG."
    case .couldNotReadPixels:
      "Could not normalize appearance fixture pixels to RGBA."
    case .dimensionMismatch(let expected, let actual):
      "Visual dimensions differ: expected \(expected), actual \(actual)."
    }
  }
}
