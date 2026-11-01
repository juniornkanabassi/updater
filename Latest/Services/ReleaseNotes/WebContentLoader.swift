//
//  WebContentLoader.swift
//  Latest
//
//  Created by Max Langer on 26.09.23.
//  Copyright © 2023 Max Langer. All rights reserved.
//

import WebKit

/// Object that loads websites for given URLs and returns their content as HTML.
@MainActor
final class WebContentLoader: NSObject {
  deinit {
    pendingContentUpdateTask?.cancel()
    loadTimeoutTask?.cancel()
  }

  /// Loads contents for the given URL.
  ///
  /// The update handler is called once after the page reaches a settled DOM state.
  func load(
    from url: URL,
    acceptsContent: (@Sendable (String) async -> Bool)? = nil,
    contentUpdateHandler: @escaping @MainActor (Result<String, Error>) -> Void
  ) {
    cancel()
    let loadID = UUID()
    currentLoadID = loadID
    currentUpdateHandler = contentUpdateHandler
    self.acceptsContent = acceptsContent
    let webView = activeWebView
    webView.stopLoading()
    currentNavigation = webView.load(URLRequest(url: url))
    scheduleLoadTimeout(for: loadID)
  }

  /// Cancels any active load and suppresses delayed content updates.
  func cancel() {
    pendingContentUpdateTask?.cancel()
    pendingContentUpdateTask = nil
    loadTimeoutTask?.cancel()
    loadTimeoutTask = nil
    currentLoadID = UUID()
    currentNavigation = nil
    currentUpdateHandler = nil
    acceptsContent = nil
    guard let webView else { return }
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "updateHandler")
    self.webView = nil
  }

  // MARK: - Accessors

  /// The web view actually loading the web contents.
  ///
  /// Required for some websites that use scripts to populate the sites contents.
  private var webView: WKWebView?

  private var activeWebView: WKWebView {
    if let webView {
      return webView
    }

    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()

    // Setup observation script
    let source = """
      if (window.__latestMutationObserver) {
      \twindow.__latestMutationObserver.disconnect();
      }
      window.__latestScheduleUpdate = function() {
      \tclearTimeout(window.__latestMutationTimer);
      \twindow.__latestMutationTimer = setTimeout(function() {
      \t\twindow.webkit.messageHandlers.updateHandler.postMessage("contentsUpdated");
      \t}, 120);
      };
      window.__latestMutationObserver = new MutationObserver(function() {
      \twindow.__latestScheduleUpdate();
      });

      window.__latestMutationObserver.observe(document.documentElement || document, { childList: true, subtree: true });
      window.__latestScheduleUpdate();
      """

    let script = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    config.userContentController.addUserScript(script)
    config.userContentController.add(MessageHandler(loader: self), name: "updateHandler")

    // Setup web view
    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = self

    self.webView = webView
    return webView
  }

  /// The current navigation object.
  private var currentNavigation: WKNavigation?

  /// The identifier for the most recent load.
  private var currentLoadID = UUID()

  /// The current update handler.
  private var acceptsContent: (@Sendable (String) async -> Bool)?

  private var currentUpdateHandler: (@MainActor (Result<String, Error>) -> Void)?

  /// Delayed content extraction work used to collapse mutation bursts.
  private var pendingContentUpdateTask: Task<Void, Never>?

  /// Timeout work for dynamic pages that never finish or never settle.
  private var loadTimeoutTask: Task<Void, Never>?

  // MARK: - Utilities

  /// Schedules a content update after the page has had a chance to settle.
  fileprivate func scheduleContentUpdate() {
    let loadID = currentLoadID
    pendingContentUpdateTask?.cancel()
    pendingContentUpdateTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled, let self, loadID == self.currentLoadID else { return }
      await self.notifyContentUpdate(for: loadID)
    }
  }

  private func scheduleLoadTimeout(for loadID: UUID) {
    loadTimeoutTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 8_000_000_000)
      guard !Task.isCancelled, let self else { return }
      self.finish(.failure(WebContentLoaderError.timedOut), for: loadID)
    }
  }

  /// Forwards the current page contents to the caller of the load method.
  private func notifyContentUpdate(for loadID: UUID) async {
    guard loadID == currentLoadID,
      currentUpdateHandler != nil,
      let webView
    else { return }

    do {
      let result = try await webView.evaluateJavaScript(
        "document.documentElement.outerHTML.toString()")
      guard !Task.isCancelled, loadID == currentLoadID,
        currentUpdateHandler != nil,
        let html = result as? String,
        !html.isEmpty
      else { return }

      if let acceptsContent, !(await acceptsContent(html)) { return }
      guard !Task.isCancelled else { return }
      finish(.success(html), for: loadID)
    } catch {
      guard !Task.isCancelled else { return }
      finish(.failure(error), for: loadID)
    }
  }

  private func finish(_ result: Result<String, Error>, for loadID: UUID) {
    guard loadID == currentLoadID, let handler = currentUpdateHandler else { return }
    // Clear ownership before invoking a callback that may start another load.
    cancel()
    handler(result)
  }

}

extension WebContentLoader: WKNavigationDelegate {

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === self.webView, navigation == currentNavigation else { return }
    scheduleContentUpdate()
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    guard webView === self.webView, navigation == currentNavigation else { return }
    finish(.failure(error), for: currentLoadID)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    guard webView === self.webView, navigation == currentNavigation else { return }
    finish(.failure(error), for: currentLoadID)
  }

}

extension WebContentLoader {
  /// WebKit retains script handlers; forwarding weakly avoids owning the loader.
  private final class MessageHandler: NSObject, WKScriptMessageHandler {
    weak var loader: WebContentLoader?
    init(loader: WebContentLoader) { self.loader = loader }
    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard let loader, message.webView === loader.webView, message.name == "updateHandler" else {
        return
      }
      loader.scheduleContentUpdate()
    }
  }
}

private enum WebContentLoaderError: Error {
  case timedOut
}
