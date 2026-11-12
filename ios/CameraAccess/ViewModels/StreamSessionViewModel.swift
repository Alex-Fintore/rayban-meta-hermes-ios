import AVFoundation
import Foundation
import MWDATCamera
import MWDATCore
import Observation
import Security
import Speech
import SwiftUI
import UIKit

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

struct HermesAskResponse: Decodable {
  let answer: String
  let sessionId: String
}

enum HermesClientError: LocalizedError {
  case invalidServerURL
  case missingToken
  case oversizedImage
  case badStatus(Int, String)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .invalidServerURL:
      return "Server URL is invalid."
    case .missingToken:
      return "Add the Hermes access token in Settings first."
    case .oversizedImage:
      return "The captured image is still larger than 5 MB after compression."
    case .badStatus(let status, let code):
      if status == 401 {
        return "Hermes rejected the access token."
      }
      return "Hermes returned \(status): \(code)."
    case .invalidResponse:
      return "Hermes returned an invalid response."
    }
  }
}

@Observable
@MainActor
final class StreamSessionViewModel {
  var currentVideoFrame: UIImage?
  var hasReceivedFirstFrame: Bool = false
  var streamingStatus: StreamingStatus = .stopped
  var showError: Bool = false
  var errorMessage: String = ""
  var requiresDATAppUpdate: Bool = false

  var capturedPhoto: UIImage?
  var showPhotoPreview: Bool = false
  var showPhotoCaptureError: Bool = false
  var isCapturingPhoto: Bool = false

  var questionText: String = ""
  var answerText: String = ""
  var isAsking: Bool = false
  var isListening: Bool = false
  var isSpeaking: Bool = false
  var isHandsFreeModeEnabled: Bool = false
  var isHandsFreeListening: Bool = false
  var isHandsFreeProcessing: Bool = false
  var handsFreeStatus: String = "Off"
  var serverURLText: String
  var accessToken: String
  var sessionId: String?

  var hasActiveDevice: Bool { sessionManager.hasActiveDevice }
  var isDeviceSessionReady: Bool { sessionManager.isReady }
  var isStreaming: Bool { streamingStatus != .stopped }
  var canAskHermes: Bool {
    !questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isAsking
  }

  @ObservationIgnored private let sessionManager: DeviceSessionManager
  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let settingsStore = HermesSettingsStore()
  @ObservationIgnored private let hermesClient = HermesClient()
  @ObservationIgnored private let speechInput = SpeechInputController()
  @ObservationIgnored private let speechOutput = SpeechOutputController()

  @ObservationIgnored private var stream: MWDATCamera.Stream?
  @ObservationIgnored private var stateListenerToken: AnyListenerToken?
  @ObservationIgnored private var videoFrameListenerToken: AnyListenerToken?
  @ObservationIgnored private var errorListenerToken: AnyListenerToken?
  @ObservationIgnored private var photoDataListenerToken: AnyListenerToken?
  @ObservationIgnored private var handsFreeCommandBuffer = HermesHandsFreeCommandBuffer()
  @ObservationIgnored private var pendingHandsFreeCommand: HermesHandsFreeCommand?
  @ObservationIgnored private var handsFreeFinalizeTask: Task<Void, Never>?
  @ObservationIgnored private var handsFreeWakeTimeoutTask: Task<Void, Never>?
  private var pendingPhotoCapture: Bool = false
  private var shouldResumeHandsFreeAfterSpeaking: Bool = false

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.sessionManager = DeviceSessionManager(wearables: wearables)
    self.serverURLText = settingsStore.serverURL
    self.accessToken = settingsStore.accessToken()
    self.sessionId = settingsStore.sessionId
    speechOutput.onFinish = { [weak self] in
      guard let self else { return }
      self.isSpeaking = false
      if self.shouldResumeHandsFreeAfterSpeaking {
        self.shouldResumeHandsFreeAfterSpeaking = false
        Task { await self.resumeHandsFreeListeningIfNeeded() }
      }
    }
  }

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      var status = try await wearables.checkPermissionStatus(permission)
      if status != .granted {
        status = try await wearables.requestPermission(permission)
      }
      guard status == .granted else {
        pendingPhotoCapture = false
        showError("Permission denied")
        return
      }
      await startSession()
    } catch {
      pendingPhotoCapture = false
      showError("Permission error: \(error.localizedDescription)")
    }
  }

  func captureFromGlasses() async {
    pendingPhotoCapture = true
    if streamingStatus == .streaming {
      pendingPhotoCapture = false
      capturePhoto()
      return
    }
    await handleStartStreaming()
  }

  func stopSession() {
    stream?.stop()
  }

  func endSession() {
    stream = nil
    clearListeners()
    streamingStatus = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    sessionManager.cleanup()
  }

  func capturePhoto() {
    guard !isCapturingPhoto, streamingStatus == .streaming else {
      showPhotoCaptureError = true
      return
    }
    isCapturingPhoto = true
    let success = stream?.capturePhoto(format: .jpeg) ?? false
    if !success {
      isCapturingPhoto = false
      showPhotoCaptureError = true
    }
  }

  func toggleListening() async {
    if isHandsFreeModeEnabled {
      stopHandsFreeMode()
    }

    if isListening {
      speechInput.stop()
      isListening = false
      return
    }

    do {
      isListening = true
      try await speechInput.start(
        onTranscript: { [weak self] transcript, _ in
          self?.questionText = transcript
        },
        onError: { [weak self] message in
          self?.isListening = false
          self?.showError("Speech recognition failed: \(message)")
        }
      )
    } catch {
      isListening = false
      showError(error.localizedDescription)
    }
  }

  func toggleHandsFreeMode() async {
    if isHandsFreeModeEnabled {
      stopHandsFreeMode()
      return
    }

    isHandsFreeModeEnabled = true
    await startHandsFreeListening()
  }

  func stopHandsFreeMode() {
    isHandsFreeModeEnabled = false
    isHandsFreeListening = false
    isHandsFreeProcessing = false
    shouldResumeHandsFreeAfterSpeaking = false
    resetHandsFreeCommandState()
    handsFreeStatus = "Off"
    speechInput.stop()
  }

  func askHermes() async {
    let text = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      showError("Enter or dictate a question first.")
      return
    }

    let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      showError(HermesClientError.missingToken.localizedDescription)
      return
    }

    guard let serverURL = URL(string: serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      showError(HermesClientError.invalidServerURL.localizedDescription)
      return
    }

    var imageData: Data?
    if let capturedPhoto {
      guard let compressed = capturedPhoto.hermesUploadJPEGData() else {
        showError(HermesClientError.oversizedImage.localizedDescription)
        return
      }
      imageData = compressed
    }

    isAsking = true
    defer { isAsking = false }

    do {
      saveSettings()
      let response = try await hermesClient.ask(
        serverURL: serverURL,
        token: token,
        text: text,
        imageData: imageData,
        sessionId: sessionId
      )
      answerText = response.answer
      sessionId = response.sessionId
      settingsStore.sessionId = response.sessionId
      speakAnswer()
    } catch {
      showError(error.localizedDescription)
    }
  }

  func speakAnswer() {
    guard !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    isSpeaking = true
    speechOutput.speak(answerText)
  }

  func stopSpeaking() {
    speechOutput.stop()
    isSpeaking = false
    if isHandsFreeModeEnabled && shouldResumeHandsFreeAfterSpeaking {
      shouldResumeHandsFreeAfterSpeaking = false
      Task { await resumeHandsFreeListeningIfNeeded() }
    }
  }

  func saveSettings() {
    settingsStore.serverURL = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      try settingsStore.saveAccessToken(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
      showError("Unable to save token: \(error.localizedDescription)")
    }
  }

  func clearToken() {
    accessToken = ""
    do {
      try settingsStore.saveAccessToken("")
    } catch {
      showError("Unable to clear token: \(error.localizedDescription)")
    }
  }

  func clearSession() {
    sessionId = nil
    settingsStore.sessionId = nil
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func dismissPhotoCaptureError() {
    showPhotoCaptureError = false
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func startSession() async {
    let deviceSession: DeviceSession
    do {
      deviceSession = try await sessionManager.getSession()
      requiresDATAppUpdate = false
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      pendingPhotoCapture = false
      requiresDATAppUpdate = true
      showError(DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription)
      return
    } catch {
      pendingPhotoCapture = false
      showError("Failed to start session: \(error.localizedDescription)")
      return
    }

    guard deviceSession.state == .started else {
      pendingPhotoCapture = false
      showError("Device session is not ready. Please try again.")
      return
    }

    let config = StreamConfiguration(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24
    )

    do {
      guard let newStream = try deviceSession.addStream(config: config) else {
        pendingPhotoCapture = false
        showError("Unable to create stream. Please try again.")
        return
      }
      stream = newStream
      streamingStatus = .waiting
      setupListeners(for: newStream)
      newStream.start()
    } catch {
      pendingPhotoCapture = false
      showError("Failed to start stream: \(error.localizedDescription)")
    }
  }

  private func setupListeners(for stream: MWDATCamera.Stream) {
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleStateChange(state) }
    }

    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      Task { @MainActor in self?.handleVideoFrame(frame) }
    }

    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleError(error) }
    }

    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in self?.handlePhotoData(data) }
    }
  }

  private func clearListeners() {
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
  }

  private func handleStateChange(_ state: StreamState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
      stream = nil
      clearListeners()
      hasReceivedFirstFrame = false
      pendingPhotoCapture = false
      sessionManager.stopCurrentSession()
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
      if pendingPhotoCapture {
        pendingPhotoCapture = false
        capturePhoto()
      }
    }
  }

  private func handleVideoFrame(_ frame: VideoFrame) {
    if let image = frame.makeUIImage() {
      currentVideoFrame = image
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
      }
    }
  }

  private func handleError(_ error: StreamError) {
    let message = error.localizedDescription
    if message != errorMessage {
      showError(message)
    }
  }

  private func handlePhotoData(_ data: PhotoData) {
    isCapturingPhoto = false
    if let image = UIImage(data: data.data) {
      capturedPhoto = image
      showPhotoPreview = true
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  private func startHandsFreeListening(resetCommandBuffer: Bool = true) async {
    guard isHandsFreeModeEnabled, !isHandsFreeProcessing else { return }

    let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      stopHandsFreeMode()
      showError(HermesClientError.missingToken.localizedDescription)
      return
    }

    if resetCommandBuffer {
      resetHandsFreeCommandState()
    }

    speechInput.stop()
    isListening = false
    isHandsFreeListening = true
    handsFreeStatus = handsFreeCommandBuffer.isAwake ? "Say command" : "Listening"

    do {
      try await speechInput.start(
        localeIdentifier: "ru-RU",
        onTranscript: { [weak self] transcript, isFinal in
          self?.handleHandsFreeTranscript(transcript, isFinal: isFinal)
        },
        onError: { [weak self] message in
          guard let self, self.isHandsFreeModeEnabled else { return }
          self.isHandsFreeListening = false
          self.handsFreeStatus = "Stopped"
          self.showError("Hands-free listening failed: \(message)")
        }
      )
    } catch {
      isHandsFreeListening = false
      isHandsFreeModeEnabled = false
      handsFreeStatus = "Off"
      showError(error.localizedDescription)
    }
  }

  private func handleHandsFreeTranscript(_ transcript: String, isFinal: Bool) {
    guard isHandsFreeModeEnabled, !isHandsFreeProcessing else { return }

    if let command = handsFreeCommandBuffer.update(transcript) {
      pendingHandsFreeCommand = command
      handsFreeWakeTimeoutTask?.cancel()
      handsFreeStatus = "Listening for command"
      scheduleHandsFreeCommandFinalize(for: command, isFinal: isFinal)
      if isFinal {
        scheduleHandsFreeRestartAfterFinal()
      }
      return
    }

    if handsFreeCommandBuffer.isAwake {
      handsFreeStatus = "Say command"
      scheduleHandsFreeWakeTimeout()
    }

    if isFinal {
      scheduleHandsFreeRestartAfterFinal()
    }
  }

  private func scheduleHandsFreeCommandFinalize(for command: HermesHandsFreeCommand, isFinal: Bool) {
    handsFreeFinalizeTask?.cancel()
    let delay = handsFreeCommandFinalizeDelay(for: command, isFinal: isFinal)

    handsFreeFinalizeTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.finalizeHandsFreeCommandIfReady()
      }
    }
  }

  private func handsFreeCommandFinalizeDelay(for command: HermesHandsFreeCommand, isFinal: Bool) -> Duration {
    let wordCount = command.question
      .split { $0.isWhitespace || $0.isPunctuation }
      .count

    if isFinal && wordCount >= 3 {
      return .milliseconds(700)
    }
    return .milliseconds(1800)
  }

  private func finalizeHandsFreeCommandIfReady() {
    guard isHandsFreeModeEnabled, !isHandsFreeProcessing, let command = pendingHandsFreeCommand else {
      return
    }

    pendingHandsFreeCommand = nil
    handsFreeFinalizeTask = nil
    handsFreeWakeTimeoutTask?.cancel()
    handsFreeCommandBuffer.reset()
    isHandsFreeProcessing = true
    isHandsFreeListening = false
    handsFreeStatus = "Heard Hermes"
    speechInput.stop()

    Task { await runHandsFreeCommand(command) }
  }

  private func scheduleHandsFreeWakeTimeout() {
    handsFreeWakeTimeoutTask?.cancel()

    handsFreeWakeTimeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, self.isHandsFreeModeEnabled, !self.isHandsFreeProcessing, self.pendingHandsFreeCommand == nil else {
          return
        }
        self.handsFreeCommandBuffer.reset()
        self.handsFreeStatus = "Listening"
      }
    }
  }

  private func scheduleHandsFreeRestartAfterFinal() {
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      await self?.restartHandsFreeListeningAfterFinalIfNeeded()
    }
  }

  private func restartHandsFreeListeningAfterFinalIfNeeded() async {
    guard isHandsFreeModeEnabled, !isHandsFreeProcessing else { return }
    await startHandsFreeListening(resetCommandBuffer: false)
  }

  private func resetHandsFreeCommandState() {
    handsFreeFinalizeTask?.cancel()
    handsFreeWakeTimeoutTask?.cancel()
    handsFreeFinalizeTask = nil
    handsFreeWakeTimeoutTask = nil
    pendingHandsFreeCommand = nil
    handsFreeCommandBuffer.reset()
  }

  private func runHandsFreeCommand(_ command: HermesHandsFreeCommand) async {
    questionText = command.question
    capturedPhoto = nil
    showPhotoPreview = false
    showPhotoCaptureError = false

    if HermesHandsFreeExecutionPolicy.shouldAttemptCapture(for: command, hasActiveDevice: hasActiveDevice) {
      handsFreeStatus = "Capturing"
      await captureFromGlasses()
      let didCapturePhoto = await waitForCapturedPhoto(timeout: 10)

      if !HermesHandsFreeExecutionPolicy.shouldAskHermes(
        for: command,
        capturedPhotoAvailable: didCapturePhoto && capturedPhoto != nil
      ) {
        answerText = "Не получилось получить кадр с очков. Проверьте, что очки подключены, раскрыты, в Developer Mode и камера не занята другим приложением."
        handsFreeStatus = "No frame"
        speakAnswer()
        await finishHandsFreeCommandAfterAnswer()
        return
      }
    }

    handsFreeStatus = "Asking"
    await askHermes()
    await finishHandsFreeCommandAfterAnswer()
  }

  private func finishHandsFreeCommandAfterAnswer() async {
    isHandsFreeProcessing = false
    if isSpeaking {
      handsFreeStatus = "Answering"
      shouldResumeHandsFreeAfterSpeaking = true
    } else {
      await resumeHandsFreeListeningIfNeeded()
    }
  }

  private func resumeHandsFreeListeningIfNeeded() async {
    guard isHandsFreeModeEnabled else {
      handsFreeStatus = "Off"
      return
    }
    guard !isHandsFreeProcessing else { return }
    await startHandsFreeListening()
  }

  private func waitForCapturedPhoto(timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if capturedPhoto != nil {
        return true
      }
      if showPhotoCaptureError {
        return false
      }
      try? await Task.sleep(for: .milliseconds(200))
    }

    return capturedPhoto != nil
  }
}

private final class HermesClient {
  private struct ServerError: Decodable {
    let error: String
  }

  func ask(
    serverURL: URL,
    token: String,
    text: String,
    imageData: Data?,
    sessionId: String?
  ) async throws -> HermesAskResponse {
    let endpoint = serverURL.appending(path: "/api/glasses/ask")
    let boundary = "Boundary-\(UUID().uuidString)"
    var request = URLRequest(url: endpoint, timeoutInterval: 245)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = makeBody(boundary: boundary, text: text, imageData: imageData, sessionId: sessionId)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw HermesClientError.invalidResponse
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let code = (try? JSONDecoder().decode(ServerError.self, from: data).error) ?? "http_error"
      throw HermesClientError.badStatus(httpResponse.statusCode, code)
    }

    do {
      return try JSONDecoder().decode(HermesAskResponse.self, from: data)
    } catch {
      throw HermesClientError.invalidResponse
    }
  }

  private func makeBody(boundary: String, text: String, imageData: Data?, sessionId: String?) -> Data {
    var body = Data()

    appendField(name: "text", value: text, boundary: boundary, to: &body)
    if let sessionId, !sessionId.isEmpty {
      appendField(name: "sessionId", value: sessionId, boundary: boundary, to: &body)
    }

    if let imageData {
      body.append("--\(boundary)\r\n")
      body.append("Content-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\r\n")
      body.append("Content-Type: image/jpeg\r\n\r\n")
      body.append(imageData)
      body.append("\r\n")
    }

    body.append("--\(boundary)--\r\n")
    return body
  }

  private func appendField(name: String, value: String, boundary: String, to body: inout Data) {
    body.append("--\(boundary)\r\n")
    body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
    body.append("\(value)\r\n")
  }
}

private final class HermesSettingsStore {
  private let serverURLKey = "hermes.serverURL"
  private let sessionIdKey = "hermes.sessionId"
  private let keychainService = "com.fintore.raybanhermes"
  private let keychainAccount = "hermes-access-token"

  var serverURL: String {
    get {
      UserDefaults.standard.string(forKey: serverURLKey)
        ?? "https://hermes.178.104.38.60.sslip.io"
    }
    set {
      UserDefaults.standard.set(newValue, forKey: serverURLKey)
    }
  }

  var sessionId: String? {
    get { UserDefaults.standard.string(forKey: sessionIdKey) }
    set {
      if let newValue {
        UserDefaults.standard.set(newValue, forKey: sessionIdKey)
      } else {
        UserDefaults.standard.removeObject(forKey: sessionIdKey)
      }
    }
  }

  func accessToken() -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
      return ""
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

  func saveAccessToken(_ token: String) throws {
    try deleteAccessToken()
    guard !token.isEmpty else { return }

    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecValueData as String: Data(token.utf8)
    ]

    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }

  private func deleteAccessToken() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }
}

private final class SpeechInputController {
  private let audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var recognitionGeneration = 0

  func start(
    localeIdentifier: String? = nil,
    onTranscript: @escaping @MainActor (String, Bool) -> Void,
    onError: @escaping @MainActor (String) -> Void
  ) async throws {
    guard await requestSpeechAuthorization() else {
      throw NSError(domain: "SpeechInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission denied."])
    }
    guard await requestMicrophoneAuthorization() else {
      throw NSError(domain: "SpeechInput", code: 2, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied."])
    }
    let recognizer = SFSpeechRecognizer(
      locale: Locale(identifier: localeIdentifier ?? Locale.current.identifier)
    )
    guard let recognizer, recognizer.isAvailable else {
      throw NSError(domain: "SpeechInput", code: 3, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is unavailable."])
    }

    stop()
    recognitionGeneration += 1
    let generation = recognitionGeneration

    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(
      .playAndRecord,
      mode: .spokenAudio,
      options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
    )
    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    recognitionRequest = request

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      request.append(buffer)
    }

    audioEngine.prepare()
    try audioEngine.start()

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self, self.recognitionGeneration == generation else { return }

      if let result {
        Task { @MainActor in onTranscript(result.bestTranscription.formattedString, result.isFinal) }
      }
      if let error {
        Task { @MainActor in onError(error.localizedDescription) }
        self.stop()
      } else if result?.isFinal == true {
        self.stop()
      }
    }
  }

  func stop() {
    recognitionGeneration += 1
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest?.endAudio()
    recognitionRequest = nil

    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
  }

  private func requestSpeechAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  private func requestMicrophoneAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }
}

private final class SpeechOutputController: NSObject, AVSpeechSynthesizerDelegate {
  var onFinish: (@MainActor () -> Void)?
  private let synthesizer = AVSpeechSynthesizer()

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func speak(_ text: String) {
    stop()
    try? AVAudioSession.sharedInstance().setCategory(
      .playback,
      mode: .spokenAudio,
      options: [.allowBluetoothHFP, .allowBluetoothA2DP]
    )
    try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = selectedVoice(for: text)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
    utterance.pitchMultiplier = 0.96
    synthesizer.speak(utterance)
  }

  func stop() {
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in
      onFinish?()
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in
      onFinish?()
    }
  }

  private func selectedVoice(for text: String) -> AVSpeechSynthesisVoice? {
    let candidates = AVSpeechSynthesisVoice.speechVoices().map {
      HermesSpeechVoiceCandidate(
        identifier: $0.identifier,
        language: $0.language,
        qualityRank: $0.hermesQualityRank
      )
    }

    if let identifier = HermesSpeechVoiceSelector.preferredVoiceIdentifier(
      for: text,
      candidates: candidates
    ) {
      return AVSpeechSynthesisVoice(identifier: identifier)
    }

    return AVSpeechSynthesisVoice(
      language: HermesSpeechVoiceSelector.preferredLanguage(for: text)
    )
  }
}

private extension AVSpeechSynthesisVoice {
  var hermesQualityRank: Int {
    switch quality {
    case .premium:
      return 3
    case .enhanced:
      return 2
    default:
      return 1
    }
  }
}

private extension UIImage {
  func hermesUploadJPEGData(maxLongSide: CGFloat = 1280, quality: CGFloat = 0.75) -> Data? {
    let longestSide = max(size.width, size.height)
    let scale = min(1, maxLongSide / longestSide)
    let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: targetSize)
    let resized = renderer.image { _ in
      draw(in: CGRect(origin: .zero, size: targetSize))
    }

    var currentQuality = quality
    var data = resized.jpegData(compressionQuality: currentQuality)
    while let current = data, current.count > 5 * 1024 * 1024, currentQuality > 0.35 {
      currentQuality -= 0.1
      data = resized.jpegData(compressionQuality: currentQuality)
    }
    guard let data, data.count <= 5 * 1024 * 1024 else {
      return nil
    }
    return data
  }
}

private extension Data {
  mutating func append(_ string: String) {
    append(Data(string.utf8))
  }
}
