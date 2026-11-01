//
//  SupportStatusInfoView.swift
//  Latest
//
//  Created by ertyoii on 19.07.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-01.
//  Licensed under GPL-3.0; see LICENSE.md.

import SwiftUI

struct SupportStatusButton: View {
  let app: App
  var showsLabel = true
  @State private var showsInfo = false

  var body: some View {
    Button {
      showsInfo.toggle()
    } label: {
      HStack(spacing: 2) {
        if app.isSourcePending {
          Image(systemName: "ellipsis")
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
          if showsLabel {
            Text(
              NSLocalizedString(
                "PendingSupportLabel", value: "Checking", comment: "Pending support lookup")
            )
            .foregroundStyle(.secondary)
          }
        } else {
          Image(nsImage: app.source.supportState.statusImage)
            .resizable()
            .scaledToFit()
            .frame(width: 16, height: 16)
          if showsLabel {
            Text(app.source.supportState.compactLabel)
          }
        }
      }
      .padding(.leading, 2)
      .padding(.trailing, 4)
      .font(.system(size: 11, weight: .bold))
      .foregroundStyle(.tint)
      .fixedSize()
      .offset(x: VisualMetrics.supportStatusHorizontalCorrection)
    }
    .buttonStyle(.plain)
    .disabled(app.isSourcePending)
    .accessibilityLabel(app.localizedSupportStatus)
    .accessibilityHint("Show support information")
    .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
      SupportStatusInfoView(app: app)
    }
  }
}

struct SupportStatusInfoView: View {
  private static let issueURL = URL(string: "https://github.com/mangerlahn/Latest/issues")!

  let app: App

  var body: some View {
    VStack(alignment: .trailing, spacing: 10) {
      HStack(alignment: .top, spacing: 8) {
        Image(nsImage: app.source.supportState.statusImage)
          .resizable()
          .scaledToFit()
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 5) {
          Text(app.source.supportState.label)
            .font(.system(size: 13, weight: .semibold))
          Text(supportDescription)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(width: 300)

      if showsReportIssue {
        Link(destination: Self.issueURL) {
          Text(
            NSLocalizedString(
              "pNJ-Hl-Qxz.title",
              tableName: "Main",
              value: "Report Issue…",
              comment: "Button title in the support status popover"
            ))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
    .padding(.top, 12)
    .padding(.leading, 5)
    .padding(.trailing, 15)
    .padding(.bottom, 15)
    .frame(width: 325, height: contentHeight, alignment: .top)
    .accessibilityElement(children: .contain)
  }

  private var contentHeight: CGFloat {
    showsReportIssue ? 132 : 98
  }

  private var showsReportIssue: Bool {
    if case .full = app.source.supportState { true } else { false }
  }

  private var supportDescription: String {
    switch app.source.supportState {
    case .none:
      NSLocalizedString("NoSupportDescription", comment: "Description for apps without support")
    case .limited:
      NSLocalizedString(
        "LimitedSupportDescription", comment: "Description for apps with limited support")
    case .full:
      NSLocalizedString("FullSupportDescription", comment: "Description for apps with full support")
    }
  }
}
