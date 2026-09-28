import Foundation

/// The voices the Reading section offers, best first (docs/design.md "Reading section"). Pure: callers pass the
/// installed voices and the user's languages.
public enum ReadingVoiceMenu {
    public struct Item: Sendable, Equatable {
        public let id: String
        /// "Ava (Premium) — English (US)".
        public let title: String
        /// The voice's name as `say -v '?'` prints it, for the list's rows ("Ava (Premium)").
        public let name: String
        public let quality: String
        /// Speaks one of the user's languages (listed before the others).
        public let preferred: Bool
    }

    /// The installed voices without the novelty voices: first those that speak one of `preferredLanguages` (the
    /// user's languages, in System Settings order), then the rest; each group by quality (Premium, Enhanced,
    /// default), then by how early the user lists the language, then by language and name. Premium and Enhanced
    /// voices are marked in their titles.
    public static func items(_ voices: [VoiceDescriptor], preferredLanguages: [String]) -> [Item] {
        let preferredCodes = preferredLanguages.compactMap(VoiceSelection.languageCode)
        let names = VoiceSelection.displayNames(voices)
        let english = Locale(identifier: "en_US")
        func languageName(_ tag: String) -> String {
            english.localizedString(forIdentifier: tag.replacingOccurrences(of: "-", with: "_")) ?? tag
        }
        func preference(_ voice: VoiceDescriptor) -> Int? {
            VoiceSelection.languageCode(voice.language).flatMap { preferredCodes.firstIndex(of: $0) }
        }
        let candidates = voices.filter { !$0.novelty }
        let sorted = candidates.sorted { lhs, rhs in
            let lhsPreference = preference(lhs), rhsPreference = preference(rhs)
            if (lhsPreference != nil) != (rhsPreference != nil) { return lhsPreference != nil }
            let lhsQuality = VoiceSelection.qualityRank(lhs.quality), rhsQuality = VoiceSelection.qualityRank(rhs.quality)
            if lhsQuality != rhsQuality { return lhsQuality > rhsQuality }
            if lhsPreference != rhsPreference { return (lhsPreference ?? 0) < (rhsPreference ?? 0) }
            let lhsLanguage = languageName(lhs.language), rhsLanguage = languageName(rhs.language)
            if lhsLanguage != rhsLanguage { return lhsLanguage < rhsLanguage }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.id < rhs.id
        }
        return sorted.map { voice in
            let name = names[voice.id] ?? voice.name
            let marked = marker(voice).map { name.contains($0) ? name : "\(name) \($0)" } ?? name
            // A name that already says its language ("Eddy (English (US))") is not followed by it again.
            let title = name.contains("(\(languageName(voice.language)))") ? marked
                : "\(marked) — \(languageName(voice.language))"
            return Item(id: voice.id, title: title, name: marked, quality: voice.quality,
                        preferred: preference(voice) != nil)
        }
    }

    /// "(Premium)" or "(Enhanced)"; nil for the default quality.
    static func marker(_ voice: VoiceDescriptor) -> String? {
        switch voice.quality {
        case "premium": "(Premium)"
        case "enhanced": "(Enhanced)"
        default: nil
        }
    }
}

/// The Reading section's Speed (0.8×–1.4×) and the speech rate it asks the renderer for. `AVSpeechUtterance` takes a
/// rate from 0 to 1 whose default, 0.5, is normal speed; how fast a rate sounds is not documented and not linear, so
/// the scale is an estimate anchored at three points (not measured against real speech yet): 0.8× is 0.42, 1× is
/// the default (no rate is passed, as `voiceislocal read` without `--rate`), 1.4× is 0.6, linear in between.
public enum ReadingSpeed {
    public static let range: ClosedRange<Double> = 0.8...1.4
    public static let standard = 1.0
    /// The slider's stops: 0.8, 0.9, … 1.4.
    public static let step = 0.1
    static let slowRate: Float = 0.42
    static let normalRate: Float = 0.5
    static let fastRate: Float = 0.6

    /// `speed` on the slider's stops, within `range`.
    public static func clamped(_ speed: Double) -> Double {
        guard speed.isFinite else { return standard }
        let bounded = min(range.upperBound, max(range.lowerBound, speed))
        return (bounded / step).rounded() * step
    }

    /// The rate for `speed`; nil at 1× (the renderer's default rate).
    public static func rate(for speed: Double) -> Float? {
        let speed = clamped(speed)
        if abs(speed - standard) < 0.001 { return nil }
        if speed < standard {
            let fraction = Float((standard - speed) / (standard - range.lowerBound))
            return normalRate - fraction * (normalRate - slowRate)
        }
        let fraction = Float((speed - standard) / (range.upperBound - standard))
        return normalRate + fraction * (fastRate - normalRate)
    }

    /// The speed a rate stands for (the inverse of `rate(for:)`), on the slider's stops; 1× for nil.
    public static func speed(for rate: Float?) -> Double {
        guard let rate, rate.isFinite else { return standard }
        if rate < normalRate {
            let fraction = Double((normalRate - rate) / (normalRate - slowRate))
            return clamped(standard - fraction * (standard - range.lowerBound))
        }
        let fraction = Double((rate - normalRate) / (fastRate - normalRate))
        return clamped(standard + fraction * (range.upperBound - standard))
    }

    /// "1.2×".
    public static func label(_ speed: Double) -> String {
        String(format: "%.1f×", clamped(speed))
    }
}
