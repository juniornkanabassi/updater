//
//  UpdateActionView.swift
//  Latest
//
//  Created by ertyoii on 19.07.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-01.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Combine
import SwiftUI

@MainActor
final class UpdateActionViewModel: ObservableObject {
  struct PresentedError: Identifiable {
    let id = UUID()
    let description: String
  }

  let app: App
  @Published private(set) var presentation: UpdateActionPresentation
  @Published var presentedError: PresentedError?

  private var observationTask: Task<Void, Never>?
  private let workspace: any ApplicationWorkspace
  private let updating: any AppUpdating

  init(
    app: App,
    workspace: any ApplicationWorkspace = MacApplicationWorkspace.shared,
    updating: any AppUpdating = AppUpdateService.shared
  ) {
    self.app = app
    self.workspace = workspace
    self.updating = updating
    let feed = updating.stateChanges(for: app.identifier)
    _presentation = Published(
      initialValue: .make(
        for: app,
        progressState: feed.current
      ))
    observationTask = Task { [weak self] in
      for await state in feed.changes {
        guard !Task.isCancelled, let self else { break }
        let next = UpdateActionPresentation.make(for: app, progressState: state)
        if self.presentation != next { self.presentation = next }
      }
    }
  }

  deinit {
    observationTask?.cancel()
  }

  func performAction() {
    switch presentation {
    case .update:
      updating.update(app)
    case .open:
      workspace.openApplication(at: app.fileURL)
    case .progress(_, _, let cancellable):
      if cancellable { updating.cancel(app) }
    case .retryTermination:
      updating.retryTermination(app)
    case .failed(let description):
      presentedError = PresentedError(description: description)
    case .waiting:
      break
    }
  }

  func retry() {
    updating.update(app)
  }
}

struct UpdateActionView: View {
  @StateObject private var viewModel: UpdateActionViewModel

  init(
    app: App,
    workspace: any ApplicationWorkspace = MacApplicationWorkspace.shared,
    updating: any AppUpdating = AppUpdateService.shared
  ) {
    _viewModel = StateObject(
      wrappedValue: UpdateActionViewModel(app: app, workspace: workspace, updating: updating))
  }

  var body: some View {
    UpdateActionSurface(
      app: viewModel.app,
      presentation: viewModel.presentation,
      performAction: viewModel.performAction
    )
    .alert(item: $viewModel.presentedError) { error in
      Alert(
        title: Text(
          String.localizedStringWithFormat(
            NSLocalizedString(
              "UpdateErrorAlertTitle",
              comment: "Title of alert stating that an app update failed"
            ),
            viewModel.app.name
          )),
        message: Text(error.description),
        primaryButton: .default(Text(NSLocalizedString("RetryAction", comment: "Retry update"))) {
          viewModel.retry()
        },
        secondaryButton: .cancel()
      )
    }
  }
}

/// Stateless rendering for the update action. Keeping queue observation and side effects
/// outside this view keeps action routing separate from presentation.
struct UpdateActionSurface: View {
  let app: App
  let presentation: UpdateActionPresentation
  let performAction: () -> Void

  init(
    app: App,
    presentation: UpdateActionPresentation,
    performAction: @escaping () -> Void
  ) {
    self.app = app
    self.presentation = presentation
    self.performAction = performAction
  }

  var body: some View {
    VStack(spacing: 5) {
      UpdateActionControl(
        appName: app.name,
        presentation: presentation,
        performAction: performAction
      )
      .frame(
        width: VisualMetrics.detailUpdateButtonWidth,
        height: VisualMetrics.detailUpdateButtonHeight
      )

      if app.updateAvailable,
        let externalUpdaterName = app.externalUpdaterName
      {
        Text(
          String(
            format: NSLocalizedString(
              "ExternalUpdateActionWithAppName",
              comment: "Explanatory label below an external update button"
            ),
            externalUpdaterName
          )
        )
        .font(.system(size: 9))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
      }
    }
    .frame(width: VisualMetrics.detailUpdateButtonWidth, height: VisualMetrics.detailIconSize)
  }
}

@MainActor
enum UpdateActionVisualStyle {
  static let backgroundColor = Color(
    .sRGB, red: 0.9488552213,
    green: 0.9487094283,
    blue: 0.9693081975,
    opacity: 1
  )
  static let highlightedBackgroundColor = Color(
    .sRGB, red: 0.7995074391,
    green: 0.8113409281,
    blue: 0.8403512836,
    opacity: 1
  )
  static let errorImage = NSImage(
    systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
  static let capsuleHorizontalInset: CGFloat = 0.25
  static let progressDiameter: CGFloat = 20
  static let progressLineWidth: CGFloat = 2.5
  static let pauseBarSize = CGSize(width: 2, height: 8)
  static let pauseBarSpacing: CGFloat = 2
}

private struct UpdateActionControl: View {
  let appName: String
  let presentation: UpdateActionPresentation
  let performAction: () -> Void

  @ViewBuilder
  var body: some View {
    switch presentation {
    case .update:
      UpdateActionCapsule(
        content: .title(NSLocalizedString("UpdateAction", comment: "Action to update an app")),
        accessibilityLabel: "Update \(appName)",
        performAction: performAction
      )
    case .open:
      UpdateActionCapsule(
        content: .title(NSLocalizedString("OpenAction", comment: "Action to open an app")),
        accessibilityLabel: "Open \(appName)",
        performAction: performAction
      )
    case .retryTermination:
      UpdateActionCapsule(
        content: .title(NSLocalizedString("RetryAction", comment: "Retry quitting the app")),
        accessibilityLabel: "Retry quitting \(appName)",
        performAction: performAction
      )
      .help("Save your work, then retry quitting \(appName) to finish the update.")
      .accessibilityIdentifier("update.retry-termination")
    case .waiting(let status):
      UpdateActionIndeterminateIndicator()
        .help(status)
        .accessibilityLabel(status)
    case .progress(let fraction, let status, let cancellable):
      Button {
        performAction()
      } label: {
        UpdateActionProgressIndicator(fraction: fraction, cancellable: cancellable)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!cancellable)
      .help(status)
      .accessibilityLabel(status)
      .accessibilityHint(cancellable ? "Cancel update" : "")
      .accessibilityIdentifier("update.progress")
    case .failed:
      UpdateActionCapsule(
        content: .image(UpdateActionVisualStyle.errorImage),
        accessibilityLabel: NSLocalizedString(
          "ErrorButtonAccessibilityTitle",
          comment: "Description of button that opens an error dialogue"
        ),
        performAction: performAction
      )
    }
  }
}

/// macOS 26 retains the established native glyph and capsule rasterization.
private struct UpdateActionCapsule: View {
  let content: UpdateActionCapsuleDrawing.Content
  let accessibilityLabel: String
  let performAction: () -> Void

  var body: some View {
    if #available(macOS 27, *) {
      button.buttonStyle(UpdateActionCapsuleStyle())
    } else {
      button.buttonStyle(UpdateActionNativeCapsuleStyle(content: content))
    }
  }

  private var button: some View {
    Button(action: performAction) {
      switch content {
      case .title(let title): Text(title)
      case .image(let image):
        if let image { Image(nsImage: image).offset(x: -0.25, y: -0.5) }
      }
    }
    .accessibilityLabel(accessibilityLabel)
  }
}

private struct UpdateActionNativeCapsuleStyle: ButtonStyle {
  let content: UpdateActionCapsuleDrawing.Content

  func makeBody(configuration: Configuration) -> some View {
    configuration.label.hidden()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        UpdateActionCapsuleDrawing(content: content, isPressed: configuration.isPressed)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
  }
}

/// macOS 26 needs AppKit's title, symbol and capsule rasterization. SwiftUI
/// owns input and actions; the native control is only a noninteractive drawing.
private struct UpdateActionCapsuleDrawing: NSViewRepresentable {
  enum Content {
    case title(String)
    case image(NSImage?)
  }

  let content: Content
  let isPressed: Bool

  func makeNSView(context: Context) -> CapsuleHostView {
    let button = PixelMatchedActionButton(frame: .zero)
    button.cell = PixelMatchedActionButtonCell()
    button.isBordered = false
    button.refusesFirstResponder = true
    button.setAccessibilityElement(false)
    button.contentTintColor = .controlAccentColor
    configure(button)
    return CapsuleHostView(button: button)
  }

  func updateNSView(_ hostView: CapsuleHostView, context: Context) {
    configure(hostView.button)
  }

  private func configure(_ button: PixelMatchedActionButton) {
    button.backgroundColor = NSColor(
      isPressed
        ? UpdateActionVisualStyle.highlightedBackgroundColor
        : UpdateActionVisualStyle.backgroundColor)
    button.highlight(isPressed)
    switch content {
    case .title(let title):
      button.title = title
      button.image = nil
    case .image(let image):
      button.title = ""
      button.image = image
    }
  }

  @MainActor
  final class CapsuleHostView: NSView {
    let button: PixelMatchedActionButton

    init(button: PixelMatchedActionButton) {
      self.button = button
      super.init(frame: .zero)
      addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
      super.layout()
      button.frame = bounds.insetBy(dx: UpdateActionVisualStyle.capsuleHorizontalInset, dy: 0)
    }
  }

}

@MainActor
private final class PixelMatchedActionButton: NSButton {
  var backgroundColor = NSColor(UpdateActionVisualStyle.backgroundColor) {
    didSet { needsDisplay = true }
  }
}

private final class PixelMatchedActionButtonCell: NSButtonCell {
  override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
    guard let button = controlView as? PixelMatchedActionButton else { return }
    let radius = cellFrame.height / 2
    button.backgroundColor.setFill()
    NSBezierPath(roundedRect: cellFrame, xRadius: radius, yRadius: radius).fill()
    super.drawInterior(withFrame: cellFrame, in: controlView)
  }

  override func drawTitle(
    _ title: NSAttributedString,
    withFrame frame: NSRect,
    in controlView: NSView
  ) -> NSRect {
    let string = NSMutableAttributedString(attributedString: title)
    let range = NSRange(location: 0, length: string.length)
    string.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
    let pointSize = font?.pointSize ?? NSFont.systemFontSize
    string.addAttribute(
      .font,
      value: NSFont.systemFont(ofSize: pointSize - 1, weight: .medium),
      range: range
    )
    var adjustedFrame = frame
    adjustedFrame.origin.y -= 1
    return super.drawTitle(string, withFrame: adjustedFrame, in: controlView)
  }

  override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
    var adjustedFrame = frame
    adjustedFrame.origin.y -= 1
    super.drawImage(image, withFrame: adjustedFrame, in: controlView)
  }
}

private struct UpdateActionCapsuleStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(Color(nsColor: .controlAccentColor))
      .offset(x: -0.25, y: -0.5)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        Capsule(style: .circular)
          .fill(
            configuration.isPressed
              ? UpdateActionVisualStyle.highlightedBackgroundColor
              : UpdateActionVisualStyle.backgroundColor
          )
          .offset(x: -0.25)
      }
      .padding(.horizontal, UpdateActionVisualStyle.capsuleHorizontalInset)
      .contentShape(Rectangle())
  }
}

private struct UpdateActionIndeterminateIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      Circle()
        .trim(from: 0, to: 0.75)
        .stroke(
          Color(nsColor: .tertiaryLabelColor),
          style: StrokeStyle(
            lineWidth: UpdateActionVisualStyle.progressLineWidth,
            lineCap: .round
          )
        )
        .rotationEffect(
          .degrees(
            reduceMotion
              ? 90 : context.date.timeIntervalSinceReferenceDate * 360
          ))
    }
    .frame(
      width: UpdateActionVisualStyle.progressDiameter,
      height: UpdateActionVisualStyle.progressDiameter
    )
  }
}

private struct UpdateActionProgressIndicator: View {
  let fraction: Double?
  let cancellable: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(paused: fraction != nil || reduceMotion)) { context in
      ZStack {
        Circle()
          .stroke(
            Color(nsColor: .tertiaryLabelColor),
            lineWidth: UpdateActionVisualStyle.progressLineWidth
          )
        Circle()
          .trim(from: 0, to: fraction ?? 0.25)
          .stroke(
            Color(nsColor: .controlAccentColor),
            style: StrokeStyle(
              lineWidth: UpdateActionVisualStyle.progressLineWidth,
              lineCap: .round
            )
          )
          .rotationEffect(
            .degrees(
              fraction == nil && !reduceMotion
                ? context.date.timeIntervalSinceReferenceDate
                  .truncatingRemainder(dividingBy: 1) * 360 : -90))

        if cancellable {
          HStack(spacing: UpdateActionVisualStyle.pauseBarSpacing) {
            ForEach(0..<2, id: \.self) { _ in
              RoundedRectangle(cornerRadius: 1)
                .fill(Color(nsColor: .controlAccentColor))
                .frame(
                  width: UpdateActionVisualStyle.pauseBarSize.width,
                  height: UpdateActionVisualStyle.pauseBarSize.height
                )
            }
          }
        }
      }
    }
    .frame(
      width: UpdateActionVisualStyle.progressDiameter,
      height: UpdateActionVisualStyle.progressDiameter
    )
  }
}
