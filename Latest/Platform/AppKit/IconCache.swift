// Copyright © 2018 Max Langer. Licensed under GPL-3.0; see LICENSE.md.

import AppKit

/// Keeps display-sized icons; filesystem access and rasterisation stay off the UI thread.
@MainActor
final class IconCache {
  static let shared = IconCache()
  private let cache = NSCache<NSString, NSImage>()
  private var pending: [String: Task<NSImage, Never>] = [:]
  // A serial worker bounds expensive AppKit/icon-service work even during fast scrolling.
  private let worker = DispatchQueue(label: "Updater.icons", qos: .utility)

  private init() {
    cache.countLimit = 256
    cache.totalCostLimit = 16 * 1_024 * 1_024
  }

  func icon(for app: App, pointSize: CGFloat = 40) async -> NSImage {
    let key = cacheKey(for: app, pointSize: pointSize)
    if let image = cache.object(forKey: key as NSString) { return image }
    if let task = pending[key] { return await task.value }
    let path = app.fileURL.standardizedFileURL.path
    let pixels = Int(ceil(pointSize * 2))
    let task = Task<NSImage, Never> {
      await withCheckedContinuation { continuation in
        worker.async {
          let image = autoreleasepool {
            Self.loadIcon(path: path, pointSize: pointSize, pixels: pixels)
          }
          continuation.resume(returning: image)
        }
      }
    }
    pending[key] = task
    let image = await task.value
    cache.setObject(image, forKey: key as NSString, cost: pixels * pixels * 4)
    pending[key] = nil
    return image
  }

  /// Memory-only lookup keeps a warm row's first frame free of placeholders.
  func cachedIcon(for app: App, pointSize: CGFloat = 40) -> NSImage? {
    cache.object(forKey: cacheKey(for: app, pointSize: pointSize) as NSString)
  }

  /// Stable across metadata refreshes, but invalidates when the bundle changes on disk.
  func cacheKey(for app: App, pointSize: CGFloat = 40) -> String {
    let path = app.fileURL.standardizedFileURL.path
    return
      "\(path)\u{0}\(app.bundle.modificationDate.timeIntervalSinceReferenceDate)\u{0}\(Int(ceil(pointSize * 2)))"
  }

  nonisolated private static func loadIcon(path: String, pointSize: CGFloat, pixels: Int) -> NSImage
  {
    assert(!Thread.isMainThread, "Icon loading must stay off the UI thread")
    let source = NSWorkspace.shared.icon(forFile: path)
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return NSImage(size: NSSize(width: pointSize, height: pointSize)) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
    image.addRepresentation(bitmap)
    return image
  }
}
