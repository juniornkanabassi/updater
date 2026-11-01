//
//  GeneralSettingsView.swift
//  Latest
//
//  Created by ertyoii on 03.06.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import SwiftUI

struct GeneralSettingsView: View {
  @ObservedObject var viewModel: SettingsViewModel
  @AppStorage(ApplicationAppearance.storageKey)
  private var appearanceRawValue = ApplicationAppearance.system.rawValue

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      settingsForm
      if viewModel.showsInstallHelperBanner {
        installHelperBanner
      }
    }
    .padding(20)
    .onAppear {
      viewModel.refreshInstallHelperAvailability()
    }
    .alert(
      "Unable to Enable Update Helper",
      isPresented: Binding(
        get: { viewModel.helperRegistrationError != nil },
        set: { if !$0 { viewModel.helperRegistrationError = nil } })
    ) {
      Button("OK", role: .cancel) { viewModel.helperRegistrationError = nil }
    } message: {
      Text(viewModel.helperRegistrationError ?? "")
    }
  }

  private var settingsForm: some View {
    VStack(spacing: 16) {
      GroupBox {
        HStack {
          Text("Appearance")
          Spacer(minLength: 16)
          appearancePicker
        }
        .padding(10)
      }

      GroupBox("App visibility") {
        VStack(alignment: .leading, spacing: 14) {
          preferenceOption(
            title: "Apps with limited support",
            description: "Update information may be inaccurate. Update these apps outside Latest.",
            isOn: limitedSupportBinding
          )

          Divider()

          preferenceOption(
            title: "Unsupported apps",
            description: "Show apps without any available update information.",
            isOn: unsupportedAppsBinding
          )
        }
        .padding(10)
      }
    }
  }

  private var appearancePicker: some View {
    Picker("Appearance", selection: $appearanceRawValue) {
      ForEach(ApplicationAppearance.allCases) { appearance in
        Text(appearance.title)
          .tag(appearance.rawValue)
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .frame(width: 230)
    .accessibilityIdentifier("settings.appearance")
  }

  private var installHelperBanner: some View {
    GroupBox {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("App Store updates")
          Text("Enable a helper to update App Store apps within Latest.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Button("Enable") {
          viewModel.registerInstallHelper()
        }
      }
      .padding(10)
    }
  }

  private func preferenceOption(
    title: String,
    description: String,
    isOn: Binding<Bool>
  ) -> some View {
    Toggle(isOn: isOn) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .toggleStyle(.switch)
    .accessibilityLabel(title)
    .accessibilityHint(description)
  }

  private var limitedSupportBinding: Binding<Bool> {
    Binding(
      get: { viewModel.includeAppsWithLimitedSupport },
      set: { viewModel.includeAppsWithLimitedSupport = $0 }
    )
  }

  private var unsupportedAppsBinding: Binding<Bool> {
    Binding(
      get: { viewModel.includeUnsupportedApps },
      set: { viewModel.includeUnsupportedApps = $0 }
    )
  }
}
