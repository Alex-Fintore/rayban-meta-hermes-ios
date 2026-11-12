import AppIntents
import Foundation

enum HermesShortcutRequestStore {
  private static let handsFreeStartRequestedKey = "hermes.shortcut.handsFreeStartRequested"

  static func requestHandsFreeStart() {
    UserDefaults.standard.set(true, forKey: handsFreeStartRequestedKey)
  }

  static func consumeHandsFreeStartRequest() -> Bool {
    let requested = UserDefaults.standard.bool(forKey: handsFreeStartRequestedKey)
    if requested {
      UserDefaults.standard.set(false, forKey: handsFreeStartRequestedKey)
    }
    return requested
  }
}

struct StartHermesHandsFreeIntent: AppIntent {
  static var title: LocalizedStringResource = "Start Hermes"
  static var description = IntentDescription("Open Rayban Hermes and start hands-free listening.")
  static var openAppWhenRun: Bool = true

  func perform() async throws -> some IntentResult {
    HermesShortcutRequestStore.requestHandsFreeStart()
    return .result()
  }
}

struct RaybanHermesShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartHermesHandsFreeIntent(),
      phrases: [
        "Start \(.applicationName)",
        "Ask \(.applicationName)",
        "Open \(.applicationName)"
      ],
      shortTitle: "Start Hermes",
      systemImageName: "eyeglasses"
    )
  }
}
