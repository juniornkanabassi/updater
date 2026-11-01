// Fork contributions © 2026 ertyoii.
// Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI

/// SwiftUI owns layout and row actions. This bridge configures capabilities
/// SwiftUI does not expose: overlay indicators and nonelastic scrolling.
struct SidebarScrollConfiguration: NSViewRepresentable {
  func makeNSView(context: Context) -> ConfigurationView {
    ConfigurationView()
  }

  func updateNSView(_ view: ConfigurationView, context: Context) {
    view.configure()
  }

  final class ConfigurationView: NSView {
    override init(frame: NSRect) {
      super.init(frame: frame)
      setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      configure()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      configure()
    }

    override func layout() {
      super.layout()
      configure()
    }

    func configure() {
      guard let scroll = enclosingScrollView else { return }
      scroll.scrollerStyle = .overlay
      scroll.autohidesScrollers = true
      scroll.verticalScrollElasticity = .none
      scroll.horizontalScrollElasticity = .none
    }
  }
}
