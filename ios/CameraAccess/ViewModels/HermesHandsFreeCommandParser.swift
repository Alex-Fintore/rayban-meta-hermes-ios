import Foundation

struct HermesHandsFreeCommand: Equatable {
  let question: String
  let shouldCapture: Bool
}

struct HermesHandsFreeCommandBuffer {
  private(set) var isAwake = false
  private var commandText = ""
  private var lastCommandSegment = ""

  mutating func update(_ transcript: String) -> HermesHandsFreeCommand? {
    if let commandText = HermesHandsFreeCommandParser.commandText(afterWakeTriggerIn: transcript) {
      isAwake = true
      return updateCommandText(commandText)
    }

    if isAwake {
      return updateCommandText(transcript)
    }

    if HermesHandsFreeCommandParser.containsWakeTrigger(transcript) {
      isAwake = true
    }

    return nil
  }

  mutating func reset() {
    isAwake = false
    commandText = ""
    lastCommandSegment = ""
  }

  private mutating func updateCommandText(_ rawText: String) -> HermesHandsFreeCommand? {
    let segment = HermesHandsFreeCommandParser.cleanCommandText(rawText)
    guard !segment.isEmpty else { return nil }

    mergeCommandSegment(segment)
    lastCommandSegment = segment
    return HermesHandsFreeCommandParser.parseCommandText(commandText)
  }

  private mutating func mergeCommandSegment(_ segment: String) {
    guard !commandText.isEmpty else {
      commandText = segment
      return
    }

    let normalizedSegment = Self.normalized(segment)
    let normalizedCommand = Self.normalized(commandText)
    let normalizedLastSegment = Self.normalized(lastCommandSegment)

    if normalizedSegment == normalizedCommand
      || normalizedCommand.hasPrefix(normalizedSegment)
      || normalizedCommand.hasSuffix(normalizedSegment) {
      return
    }

    if normalizedSegment.hasPrefix(normalizedCommand) {
      commandText = segment
      return
    }

    if !normalizedLastSegment.isEmpty,
       normalizedSegment.hasPrefix(normalizedLastSegment),
       normalizedCommand.hasSuffix(normalizedLastSegment) {
      replaceLastCommandSegment(with: segment)
      return
    }

    commandText += " \(segment)"
  }

  private mutating func replaceLastCommandSegment(with segment: String) {
    guard commandText.hasSuffix(lastCommandSegment) else {
      commandText += " \(segment)"
      return
    }

    commandText.removeLast(lastCommandSegment.count)
    commandText = HermesHandsFreeCommandParser.cleanCommandText("\(commandText) \(segment)")
  }

  private static func normalized(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .split { $0.isWhitespace || $0.isPunctuation }
      .joined(separator: " ")
  }
}

enum HermesHandsFreeCommandParser {
  private static let triggers = ["гермес", "hermes"]
  private static let visualQuestionMarkers = [
    "что передо мной",
    "передо мной",
    "что впереди",
    "что перед нами",
    "перед нами",
    "что я вижу",
    "что я сейчас вижу",
    "я сейчас вижу",
    "что вижу",
    "вижу",
    "что это",
    "что здесь",
    "на что я смотрю",
    "посмотри",
    "сфотограф",
    "сделай фото",
    "сделай сним",
    "фотк",
    "фото",
    "камера",
    "прочитай это",
    "опиши это",
    "опиши карт",
    "what is this",
    "what's this",
    "what am i looking at",
    "what is in front of me",
    "what's in front of me",
    "in front of me",
    "look at",
    "describe this",
    "read this",
    "take a photo",
    "take a picture",
    "camera"
  ]

  static func containsWakeTrigger(_ transcript: String) -> Bool {
    let trimmedTranscript = transcript
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedTranscript.isEmpty else { return false }

    return triggers.contains { trigger in
      trimmedTranscript.range(
        of: trigger,
        options: [.caseInsensitive, .diacriticInsensitive]
      ) != nil
    }
  }

  static func parse(_ transcript: String) -> HermesHandsFreeCommand? {
    guard let rawQuestion = commandText(afterWakeTriggerIn: transcript) else {
      return nil
    }

    return parseCommandText(rawQuestion)
  }

  static func commandText(afterWakeTriggerIn transcript: String) -> String? {
    let trimmedTranscript = transcript
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedTranscript.isEmpty else { return nil }

    for trigger in triggers {
      guard let range = trimmedTranscript.range(
        of: trigger,
        options: [.caseInsensitive, .diacriticInsensitive]
      ) else { continue }

      return String(trimmedTranscript[range.upperBound...])
    }

    return nil
  }

  static func parseCommandText(_ text: String) -> HermesHandsFreeCommand? {
    let rawQuestion = cleanCommandText(text)

    guard !rawQuestion.isEmpty else {
      return nil
    }

    let question = rawQuestion.prefix(1).uppercased() + rawQuestion.dropFirst()
    return HermesHandsFreeCommand(
      question: question,
      shouldCapture: shouldCapture(for: rawQuestion)
    )
  }

  static func cleanCommandText(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
  }

  private static func shouldCapture(for question: String) -> Bool {
    let normalizedQuestion = question.lowercased()
    return visualQuestionMarkers.contains { marker in
      normalizedQuestion.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
  }
}

enum HermesHandsFreeExecutionPolicy {
  static func shouldAttemptCapture(for command: HermesHandsFreeCommand, hasActiveDevice _: Bool) -> Bool {
    command.shouldCapture
  }

  static func shouldAskHermes(for command: HermesHandsFreeCommand, capturedPhotoAvailable: Bool) -> Bool {
    !command.shouldCapture || capturedPhotoAvailable
  }
}
