// Fork contributions © 2026 ertyoii.
// Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI

/// One update-state subscription owns both the status dot and progress control.
struct SidebarUpdateStatus: View {
  let app: App
  let selection: UpdateRowSelection
  let showsSupportStatus: Bool
  let updating: any AppUpdating
  @State private var observed: ObservedState?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private struct ObservationKey: Equatable {
    let app: App.Bundle.Identifier
    let service: ObjectIdentifier
  }

  private struct ObservedState {
    let key: ObservationKey
    let presentation: UpdateActionPresentation
  }

  private var key: ObservationKey {
    ObservationKey(app: app.identifier, service: ObjectIdentifier(updating))
  }

  private var presentation: UpdateActionPresentation {
    if let observed, observed.key == key { return observed.presentation }
    return .make(for: app, progressState: updating.state(for: app.identifier))
  }

  var body: some View {
    Group {
      switch presentation {
      case .retryTermination:
        Button {
          updating.retryTermination(app)
        } label: {
          Image(systemName: "arrow.clockwise")
            .foregroundStyle(
              Color(
                nsColor: selection.usesActiveSelectionColors
                  ? .alternateSelectedControlTextColor : .controlAccentColor))
        }
        .buttonStyle(.plain)
        .help("Save your work, then retry quitting \(app.name) to finish the update.")
        .accessibilityLabel("Retry quitting \(app.name)")
        .accessibilityIdentifier("updates.retry-termination")
      case .waiting(let status):
        TimelineView(.animation(paused: reduceMotion)) { context in
          SidebarIndicatorGlyph(
            fraction: nil,
            angle: reduceMotion
              ? 0
              : context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1) * 360,
            tint: Color(
              nsColor: selection.usesActiveSelectionColors
                ? .alternateSelectedControlTextColor : .tertiaryLabelColor))
        }
        .help(status)
        .accessibilityLabel(status)
      case .progress(let fraction, let status, let cancellable):
        Button {
          updating.cancel(app)
        } label: {
          Color.clear
        }
        .buttonStyle(
          SidebarProgressButtonStyle(
            fraction: fraction, selection: selection, cancellable: cancellable)
        )
        .disabled(!cancellable)
        .help(status)
        .accessibilityLabel(status)
        .accessibilityHint(cancellable ? "Cancel update" : "")
        .accessibilityIdentifier("updates.progress")
      case .update, .open, .failed:
        Group {
          if app.isSourcePending {
            Image(systemName: "ellipsis").foregroundStyle(.secondary)
          } else {
            Image(nsImage: app.source.supportState.statusImage)
          }
        }
        .frame(width: 16, height: 16)
        .offset(y: -13)
        .opacity(showsSupportStatus ? 1 : 0)
        .help(app.localizedSupportStatus)
        .accessibilityLabel(app.localizedSupportStatus)
        .accessibilityHidden(!showsSupportStatus)
      }
    }
    .frame(width: 24, height: 24)
    .task(id: key) {
      let key = key
      for await state in updating.states(for: app.identifier) {
        guard !Task.isCancelled else { return }
        let next = ObservedState(key: key, presentation: .make(for: app, progressState: state))
        if observed?.key != key || observed?.presentation != next.presentation { observed = next }
      }
    }
  }
}

private struct SidebarProgressButtonStyle: ButtonStyle {
  let fraction: Double?
  let selection: UpdateRowSelection
  let cancellable: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    let color: NSColor =
      selection.usesActiveSelectionColors
      ? .alternateSelectedControlTextColor : .controlAccentColor
    TimelineView(.animation(paused: fraction != nil || reduceMotion)) { context in
      SidebarIndicatorGlyph(
        fraction: fraction,
        angle: fraction == nil && !reduceMotion
          ? context.date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 1) * 360 : -90,
        tint: Color(nsColor: configuration.isPressed ? color.withSystemEffect(.pressed) : color),
        cancellable: cancellable
      )
    }
    .frame(width: 24, height: 24)
    .contentShape(Rectangle())
    .animation(reduceMotion ? nil : .linear(duration: 0.2), value: fraction)
  }
}

/// Uses the original 24-point control's paths and backing-pixel alignment.
private struct SidebarIndicatorGlyph: View, Animatable {
  var fraction: Double?
  let angle: Double
  let tint: Color
  var cancellable = true
  @Environment(\.displayScale) private var displayScale
  @Environment(\.self) private var environment

  var animatableData: Double {
    get { fraction ?? 0 }
    set { if fraction != nil { fraction = newValue } }
  }

  var body: some View {
    Canvas { context, size in
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      let radius = size.height * 0.4
      context.withCGContext { cg in
        let resolvedTint = tint.resolve(in: environment).cgColor
        cg.setLineWidth(2.5)
        if let fraction {
          let minX = floor((center.x - radius) * displayScale) / displayScale
          let minY = floor((center.y - radius) * displayScale) / displayScale
          let maxX = ceil((center.x + radius) * displayScale) / displayScale
          let maxY = ceil((center.y + radius) * displayScale) / displayScale
          cg.setStrokeColor(Color(nsColor: .tertiaryLabelColor).resolve(in: environment).cgColor)
          cg.addPath(
            SidebarIndicatorPaths.ring(
              in: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            )
            .cgPath)
          cg.strokePath()
          cg.setFillColor(resolvedTint)
          if cancellable {
            for offset in [-2.0, 2.0] {
              cg.addPath(
                SidebarIndicatorPaths.pauseMark(
                  at: CGPoint(x: center.x + offset, y: center.y)
                ).cgPath)
              cg.fillPath()
            }
          }
          guard fraction > 0 else { return }
        }
        cg.setLineCap(.round)
        cg.setStrokeColor(resolvedTint)
        let arc = SidebarIndicatorPaths.arc(
          center: center, radii: CGSize(width: radius, height: radius), angle: angle,
          sweep: fraction.map { $0 * 360 } ?? 270)
        cg.addPath(arc.cgPath)
        cg.strokePath()
      }
    }
  }
}

/// SwiftUI paths with the original cubic curves. Building the backing CGPath
/// keeps double precision; Path's mutating builders round points to Float.
enum SidebarIndicatorPaths {
  static func ring(in rect: CGRect) -> Path {
    arc(
      center: CGPoint(x: rect.midX, y: rect.midY),
      radii: CGSize(width: rect.width / 2, height: rect.height / 2), angle: -45, sweep: 360)
  }

  static func pauseMark(at center: CGPoint) -> Path {
    let path = CGMutablePath()
    let x = center.x
    let y = center.y
    // The original rounded rectangle uses this five-decimal cubic coefficient.
    let curve = 0.55228
    path.move(to: CGPoint(x: x, y: y + 4))
    path.addCurve(
      to: CGPoint(x: x - 1, y: y + 3),
      control1: CGPoint(x: x - curve, y: y + 4),
      control2: CGPoint(x: x - 1, y: y + 3 + curve))
    path.addLine(to: CGPoint(x: x - 1, y: y - 3))
    path.addCurve(
      to: CGPoint(x: x, y: y - 4),
      control1: CGPoint(x: x - 1, y: y - 3 - curve),
      control2: CGPoint(x: x - curve, y: y - 4))
    path.addLine(to: CGPoint(x: x, y: y - 4))
    path.addCurve(
      to: CGPoint(x: x + 1, y: y - 3),
      control1: CGPoint(x: x + curve, y: y - 4),
      control2: CGPoint(x: x + 1, y: y - 3 - curve))
    path.addLine(to: CGPoint(x: x + 1, y: y + 3))
    path.addCurve(
      to: CGPoint(x: x, y: y + 4),
      control1: CGPoint(x: x + 1, y: y + 3 + curve),
      control2: CGPoint(x: x + curve, y: y + 4))
    path.closeSubpath()
    return Path(path)
  }

  static func arc(center: CGPoint, radii: CGSize, angle: Double, sweep: Double) -> Path {
    let path = CGMutablePath()
    var theta = angle * .pi / 180
    let end = (angle + sweep) * .pi / 180
    func point(_ angle: Double) -> CGPoint {
      CGPoint(
        x: center.x + radii.width * cos(angle), y: center.y + radii.height * sin(angle))
    }
    path.move(to: point(theta))
    while theta < end {
      let next = min(theta + .pi / 2, end)
      let tangent = 4 / 3.0 * tan((next - theta) / 4)
      let startPoint = point(theta)
      let endPoint = point(next)
      path.addCurve(
        to: endPoint,
        control1: CGPoint(
          x: startPoint.x - radii.width * sin(theta) * tangent,
          y: startPoint.y + radii.height * cos(theta) * tangent),
        control2: CGPoint(
          x: endPoint.x + radii.width * sin(next) * tangent,
          y: endPoint.y - radii.height * cos(next) * tangent))
      theta = next
    }
    return Path(path)
  }
}
