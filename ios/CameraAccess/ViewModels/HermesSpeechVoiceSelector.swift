import Foundation

struct HermesSpeechVoiceCandidate: Equatable {
  let identifier: String
  let language: String
  let qualityRank: Int
}

enum HermesSpeechVoiceSelector {
  static func preferredVoiceIdentifier(
    for text: String,
    candidates: [HermesSpeechVoiceCandidate],
    fallbackLocaleIdentifier: String = Locale.current.identifier
  ) -> String? {
    let language = preferredLanguage(for: text, fallbackLocaleIdentifier: fallbackLocaleIdentifier)
    let languagePrefix = String(language.prefix(2)).lowercased()
    let exactMatches = candidates.filter { $0.language.caseInsensitiveCompare(language) == .orderedSame }
    let languageMatches = exactMatches.isEmpty
      ? candidates.filter { $0.language.lowercased().hasPrefix(languagePrefix) }
      : exactMatches
    let fallbackMatches = candidates.filter { $0.language.lowercased().hasPrefix("en") }
    let pool = !languageMatches.isEmpty ? languageMatches : fallbackMatches

    return pool.sorted {
      if $0.qualityRank != $1.qualityRank {
        return $0.qualityRank > $1.qualityRank
      }
      return $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending
    }.first?.identifier
  }

  static func preferredLanguage(
    for text: String,
    fallbackLocaleIdentifier: String = Locale.current.identifier
  ) -> String {
    if text.unicodeScalars.contains(where: isCyrillic) {
      return "ru-RU"
    }

    let normalizedIdentifier = fallbackLocaleIdentifier.replacingOccurrences(of: "_", with: "-")
    let languageCode = Locale(identifier: normalizedIdentifier).language.languageCode?.identifier.lowercased()

    switch languageCode {
    case "ru":
      return "ru-RU"
    case "en":
      return "en-US"
    default:
      return normalizedIdentifier.isEmpty ? "en-US" : normalizedIdentifier
    }
  }

  private static func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
    (0x0400...0x052F).contains(Int(scalar.value))
      || (0x2DE0...0x2DFF).contains(Int(scalar.value))
      || (0xA640...0xA69F).contains(Int(scalar.value))
  }
}
