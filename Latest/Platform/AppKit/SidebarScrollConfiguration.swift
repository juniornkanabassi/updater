// Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI

/// SwiftUI does not expose this native table option. Preserve pinned section headers
/// without replacing the list's own scrolling, hit testing or row rendering.
struct SidebarScrollConfiguration: NSViewRepresentable {
  func makeNSView(context: Context) -> SidebarSectionHeadersView {
    SidebarSectionHeadersView()
  }

  func updateNSView(_ view: SidebarSectionHeadersView, context: Context) {
    view.scheduleConfiguration()
  }
}

final class SidebarSectionHeadersView: NSView {
  private var configurationScheduled = false
  private weak var configuredTable: NSTableView?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    scheduleConfiguration()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    scheduleConfiguration()
  }

  override func layout() {
    super.layout()
    scheduleConfiguration()
  }

  func scheduleConfiguration() {
    guard !configurationScheduled else { return }
    if let table = configuredTable, table.window === window, table.floatsGroupRows { return }
    configurationScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.configurationScheduled = false
      self.configureNearestTable()
    }
  }

  private func configureNearestTable() {
    func table(in view: NSView) -> NSTableView? {
      if let table = view as? NSTableView { return table }
      return view.subviews.lazy.compactMap { table(in: $0) }.first
    }
    var ancestor = superview
    while let view = ancestor {
      if let table = table(in: view) {
        if !table.floatsGroupRows { table.floatsGroupRows = true }
        configuredTable = table
        return
      }
      ancestor = view.superview
    }
  }
}
