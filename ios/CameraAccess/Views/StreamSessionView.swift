import MWDATCore
import SwiftUI

struct StreamSessionView: View {
  @Environment(\.scenePhase) private var scenePhase
  let wearables: WearablesInterface
  @Bindable var wearablesViewModel: WearablesViewModel
  @State private var viewModel: StreamSessionViewModel
  @State private var showSettings = false
  @State private var didShowInitialSettings = false

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = State(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          ConnectionCard(
            wearablesViewModel: wearablesViewModel,
            streamViewModel: viewModel
          )

          CameraCaptureCard(viewModel: viewModel)
          AskCard(viewModel: viewModel)
          HandsFreeCard(viewModel: viewModel)
          AnswerCard(viewModel: viewModel)
        }
        .padding(16)
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("Rayban Hermes")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showSettings = true
          } label: {
            Image(systemName: "gearshape")
          }
          .accessibilityLabel("Settings")
        }
      }
    }
    .sheet(isPresented: $showSettings) {
      SettingsSheet(viewModel: viewModel)
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") {
        viewModel.dismissError()
      }
    } message: {
      Text(viewModel.errorMessage)
    }
    .alert("Photo capture failed", isPresented: $viewModel.showPhotoCaptureError) {
      Button("OK") {
        viewModel.dismissPhotoCaptureError()
      }
    } message: {
      Text("Unable to capture a frame from the glasses. Make sure the glasses are connected, unfolded, in Developer Mode, and not busy in another app.")
    }
    .onAppear {
      guard !didShowInitialSettings else { return }
      didShowInitialSettings = true
      if viewModel.accessToken.isEmpty {
        showSettings = true
      }
      handleShortcutStartIfNeeded()
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else { return }
      handleShortcutStartIfNeeded()
    }
  }

  private func handleShortcutStartIfNeeded() {
    guard HermesShortcutRequestStore.consumeHandsFreeStartRequest() else { return }
    guard !viewModel.isHandsFreeModeEnabled else { return }
    Task { await viewModel.toggleHandsFreeMode() }
  }
}

private struct ConnectionCard: View {
  var wearablesViewModel: WearablesViewModel
  var streamViewModel: StreamSessionViewModel

  private var status: (label: String, color: Color) {
    switch wearablesViewModel.registrationState {
    case .registered:
      return ("connected", .green)
    case .registering:
      return ("connecting", .orange)
    case .available:
      return ("disconnected", .secondary)
    case .unavailable:
      return ("SDK unavailable", .red)
    @unknown default:
      return ("unknown", .red)
    }
  }

  private var deviceSummary: String {
    if !wearablesViewModel.devices.isEmpty {
      return wearablesViewModel.devices.map { String(describing: $0) }.joined(separator: ", ")
    }
    if streamViewModel.hasActiveDevice {
      return "Active glasses ready"
    }
    return "No active glasses detected"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("Glasses", systemImage: "eyeglasses")
          .font(.headline)
        Spacer()
        Text(status.label)
          .font(.caption.weight(.semibold))
          .foregroundStyle(status.color)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(status.color.opacity(0.12))
          .clipShape(Capsule())
      }

      Text(deviceSummary)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      if wearablesViewModel.requiresFirmwareUpdate || streamViewModel.requiresDATAppUpdate {
        VStack(spacing: 8) {
          if wearablesViewModel.requiresFirmwareUpdate {
            Button {
              Task { await wearablesViewModel.openFirmwareUpdate() }
            } label: {
              Label("Update firmware", systemImage: "arrow.triangle.2.circlepath")
            }
          }

          if streamViewModel.requiresDATAppUpdate {
            Button {
              Task { await wearablesViewModel.openDATGlassesAppUpdate() }
            } label: {
              Label("Update app on glasses", systemImage: "app.badge")
            }
          }
        }
        .buttonStyle(.bordered)
      }

      HStack(spacing: 10) {
        CustomButton(
          title: wearablesViewModel.registrationState == .registering ? "Connecting..." : "Connect glasses",
          style: .primary,
          isDisabled: wearablesViewModel.registrationState == .registering
        ) {
          wearablesViewModel.connectGlasses()
        }

        Button(role: .destructive) {
          wearablesViewModel.disconnectGlasses()
        } label: {
          Image(systemName: "xmark.circle")
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .disabled(wearablesViewModel.registrationState != .registered)
      }
    }
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct CameraCaptureCard: View {
  @Bindable var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("Camera frame", systemImage: "camera")
          .font(.headline)
        Spacer()
        if viewModel.isStreaming {
          Text("streaming")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
        }
      }

      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(.tertiarySystemGroupedBackground))

        if let photo = viewModel.capturedPhoto {
          Image(uiImage: photo)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let frame = viewModel.currentVideoFrame {
          Image(uiImage: frame)
            .resizable()
            .scaledToFill()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
          VStack(spacing: 8) {
            Image(systemName: "viewfinder")
              .font(.system(size: 34))
              .foregroundStyle(.secondary)
            Text("No frame captured")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: .infinity)
      .aspectRatio(4 / 3, contentMode: .fit)

      HStack(spacing: 10) {
        CustomButton(
          title: viewModel.isCapturingPhoto ? "Capturing..." : "Capture from glasses",
          style: .primary,
          isDisabled: viewModel.isCapturingPhoto
        ) {
          Task { await viewModel.captureFromGlasses() }
        }

        Button {
          viewModel.stopSession()
        } label: {
          Image(systemName: "stop.fill")
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .disabled(!viewModel.isStreaming)
      }
    }
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct AskCard: View {
  @Bindable var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Question", systemImage: "text.bubble")
        .font(.headline)

      TextField("Ask Hermes what to do with this frame", text: $viewModel.questionText, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(3...6)

      HStack(spacing: 10) {
        Button {
          Task { await viewModel.toggleListening() }
        } label: {
          Label(viewModel.isListening ? "Stop" : "Tap to speak", systemImage: viewModel.isListening ? "mic.fill" : "mic")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)

        Button {
          viewModel.questionText = ""
        } label: {
          Image(systemName: "trash")
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.questionText.isEmpty)
      }

      CustomButton(
        title: viewModel.isAsking ? "Asking Hermes..." : "Ask Hermes",
        style: .primary,
        isDisabled: !viewModel.canAskHermes
      ) {
        Task { await viewModel.askHermes() }
      }
    }
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct HandsFreeCard: View {
  @Bindable var viewModel: StreamSessionViewModel

  private var statusColor: Color {
    if viewModel.isHandsFreeProcessing || viewModel.isHandsFreeListening {
      return .green
    }
    return viewModel.isHandsFreeModeEnabled ? .orange : .secondary
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Label(
          "Hands-free",
          systemImage: viewModel.isHandsFreeListening ? "waveform.circle.fill" : "waveform.circle"
        )
        .font(.headline)

        Spacer()

        Text(viewModel.handsFreeStatus)
          .font(.caption.weight(.semibold))
          .foregroundStyle(statusColor)
          .lineLimit(1)
      }

      Toggle(isOn: Binding(
        get: { viewModel.isHandsFreeModeEnabled },
        set: { _ in
          Task { await viewModel.toggleHandsFreeMode() }
        }
      )) {
        Label("Hermes wake phrase", systemImage: "mic.badge.plus")
      }
      .toggleStyle(.switch)

      if viewModel.isHandsFreeProcessing {
        ProgressView()
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct AnswerCard: View {
  @Bindable var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("Answer", systemImage: "speaker.wave.2")
          .font(.headline)
        Spacer()
        if let sessionId = viewModel.sessionId, !sessionId.isEmpty {
          Text(sessionId)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Text(viewModel.answerText.isEmpty ? "Hermes answer will appear here." : viewModel.answerText)
        .font(.body)
        .foregroundStyle(viewModel.answerText.isEmpty ? .secondary : .primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

      HStack(spacing: 10) {
        Button {
          viewModel.speakAnswer()
        } label: {
          Label("Speak", systemImage: "play.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.answerText.isEmpty)

        Button(role: .destructive) {
          viewModel.stopSpeaking()
        } label: {
          Label("Stop", systemImage: "stop.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!viewModel.isSpeaking)
      }
    }
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct SettingsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var viewModel: StreamSessionViewModel

  var body: some View {
    NavigationStack {
      Form {
        Section("Hermes") {
          TextField("Server URL", text: $viewModel.serverURLText)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)

          SecureField("Access Token", text: $viewModel.accessToken)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }

        Section("Session") {
          Text(viewModel.sessionId ?? "No active session")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)

          Button("Clear session") {
            viewModel.clearSession()
          }
          .disabled(viewModel.sessionId == nil)
        }

        Section {
          Button("Clear token", role: .destructive) {
            viewModel.clearToken()
          }
        }
      }
      .navigationTitle("Settings")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            viewModel.saveSettings()
            dismiss()
          }
        }
      }
    }
  }
}
