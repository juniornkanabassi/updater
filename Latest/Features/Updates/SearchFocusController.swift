//
//  SearchFocusController.swift
//  Latest
//
//  Created by ertyoii on 31.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Combine

@MainActor
final class SearchFocusController: ObservableObject {
  @Published private(set) var request: UInt?
  private weak var previousWindow: NSWindow?
  private weak var previousResponder: NSResponder?

  func focus() {
    if let window = NSApp.keyWindow, let responder = window.firstResponder,
      (responder as? NSTextView)?.isFieldEditor != true
    {
      // Repeated Find commands must keep the destination from before editing.
      previousWindow = window
      previousResponder = responder
    }
    request = (request ?? 0) &+ 1
  }

  func restorePreviousResponder() -> Bool {
    defer {
      previousWindow = nil
      previousResponder = nil
    }
    guard let window = previousWindow, window.isVisible, let responder = previousResponder else {
      return false
    }
    if let view = responder as? NSView, view.window !== window { return false }
    return window.makeFirstResponder(responder)
  }
}
