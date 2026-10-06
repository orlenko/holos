import Foundation

/// How the deep transcription pass chooses the language of each passage of a meeting in several languages
/// (docs/meeting-design.md §4.16). Pure: the voice activity and the model's language scores are passed in, so it is
/// tested without a model.
///
/// 1. Passages: each stretch the transcriber decodes (a voice-activity chunk of at most 20 s) is cut into passages at
///    its pauses: frames of `frameSeconds` are speech when they are within `speechRangeDB` of the stretch's loud
///    frames (and above `floorDB`), so a quiet room or a call's level does not matter; speech runs are joined across
///    pauses shorter than `pauseSeconds`, and each passage is cut at the middle of a pause, so the passages cover the
///    stretch. A passage with less than `minimumSpeechSeconds` of speech ("Okay.", "Merci.") is joined to the
///    neighbour it is closer to (the shorter pause), as Whisper cannot tell a language from a word or two.
/// 2. Each passage's language is the one of the meeting's languages the model scores highest for it: Whisper's
///    language-detection logits (its first decoding step), kept for those languages only and turned into
///    probabilities among them; a tie goes to the language listed first.
/// 3. A passage whose language the model is unsure of (below `confidentProbability`) often holds two languages (two
///    speakers with no clear pause between them, or one switching): it is halved at its longest pause (else its
///    quietest frame), leaving at least `minimumSpeechSeconds` of speech on each side, and each half's language is
///    chosen on its own, at most `maximumSplitDepth` times over. One too short to halve keeps its best language.
/// 4. Adjacent passages in the same language are decoded together; a change of language cuts the stretch where the
///    passages meet.
enum WhisperLanguagePick {
    /// The voice-activity frame (as WhisperKit's `EnergyVAD` has it).
    static let frameSeconds = 0.1
    /// A frame is speech when its level is within this many dB of the stretch's loud frames (`loudShare`)…
    static let speechRangeDB = 20.0
    /// …the level this share of its frames stay under…
    static let loudShare = 0.9
    /// …and above this level (dBFS): near-silence is never speech (the deep transcription guards' threshold).
    static let floorDB = -50.0
    /// Speech runs closer than this are one passage: most pauses inside one speaker's sentences are shorter. A change
    /// of speaker (or of language) after a shorter pause is found by halving the passage when its language is unsure
    /// (rule 3).
    static let pauseSeconds = 0.5
    /// A passage with less speech than this is joined to its closer neighbour.
    static let minimumSpeechSeconds = 2.0
    /// A passage whose best language scores less than this is halved, when it is long enough.
    static let confidentProbability = 0.9
    /// A passage is halved at most this many times over.
    static let maximumSplitDepth = 3

    /// One passage of a stretch: the samples it covers, and the speech in it, both in samples from the stretch's
    /// start.
    struct Passage: Equatable {
        var range: Range<Int>
        var speech: Range<Int>
    }

    /// The RMS level (dBFS, -120 for digital silence) of each frame of `frameSamples` of `samples` (the last frame
    /// may be shorter).
    static func levels(_ samples: [Float], frameSamples: Int) -> [Double] {
        let frame = max(1, frameSamples)
        var levels: [Double] = []
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + frame)
            var sum = 0.0
            for index in start..<end { sum += Double(samples[index]) * Double(samples[index]) }
            let rms = (sum / Double(end - start)).squareRoot()
            levels.append(rms > 0 ? max(-120, 20 * log10(rms)) : -120)
            start = end
        }
        return levels
    }

    /// One flag per frame of `frameSamples` of `samples`: whether it is speech (`activity(levels:)`).
    static func activity(_ samples: [Float], frameSamples: Int) -> [Bool] {
        activity(levels: levels(samples, frameSamples: frameSamples))
    }

    /// Whether each frame of these `levels` is speech: its level against the stretch's own loud frames
    /// (`speechRangeDB`, `loudShare`, `floorDB`).
    static func activity(levels: [Double]) -> [Bool] {
        guard !levels.isEmpty else { return [] }
        let sorted = levels.sorted()
        let loud = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * loudShare))]
        let threshold = max(floorDB, loud - speechRangeDB)
        return levels.map { $0 > threshold }
    }

    /// The passages of a stretch of `total` samples, from its voice activity (one flag per frame of `frameSamples`):
    /// speech runs joined across pauses shorter than `pauseFrames`, those with less than `minimumSpeechSamples` of
    /// speech joined to their closer neighbour, each passage cut at the middle of the pause before and after it. A
    /// stretch with no speech, or one run, is one passage.
    static func passages(activity: [Bool], frameSamples: Int, total: Int,
                         pauseFrames: Int = Int((pauseSeconds / frameSeconds).rounded()),
                         minimumSpeechSamples: Int = Int(minimumSpeechSeconds * 16_000)) -> [Passage] {
        guard total > 0 else { return [] }
        let frame = max(1, frameSamples)
        // Speech runs, in frames, joined across short pauses.
        var runs: [Range<Int>] = []
        var index = 0
        while index < activity.count {
            guard activity[index] else { index += 1; continue }
            var end = index
            while end < activity.count, activity[end] { end += 1 }
            if let last = runs.last, index - last.upperBound < max(1, pauseFrames) {
                runs[runs.count - 1] = last.lowerBound..<end
            } else {
                runs.append(index..<end)
            }
            index = end
        }
        var speech = runs.map { run in
            min(total, run.lowerBound * frame)..<min(total, run.upperBound * frame)
        }.filter { !$0.isEmpty }
        guard speech.count > 1 else {
            return [Passage(range: 0..<total, speech: speech.first ?? 0..<total)]
        }
        // Short ones joined to the closer neighbour (the shorter pause), the shortest first.
        while speech.count > 1,
              let short = speech.indices.filter({ speech[$0].count < minimumSpeechSamples })
                  .min(by: { speech[$0].count < speech[$1].count }) {
            let before = short > 0 ? speech[short].lowerBound - speech[short - 1].upperBound : Int.max
            let after = short < speech.count - 1 ? speech[short + 1].lowerBound - speech[short].upperBound : Int.max
            let other = before <= after ? short - 1 : short + 1
            let first = min(short, other)
            speech[first] = speech[first].lowerBound..<speech[first + 1].upperBound
            speech.remove(at: first + 1)
        }
        var out: [Passage] = []
        for position in speech.indices {
            let start = position == 0 ? 0 : (speech[position - 1].upperBound + speech[position].lowerBound) / 2
            let end = position == speech.count - 1 ? total
                : (speech[position].upperBound + speech[position + 1].lowerBound) / 2
            out.append(Passage(range: start..<end, speech: speech[position]))
        }
        return out
    }

    /// Where to halve `passage` when its language is unsure (rule 3): the middle of the longest pause in its speech
    /// (frames of `frameSamples` whose `activity` is false) that leaves at least `minimumSpeechSamples` of speech on
    /// each side, the one nearer the middle on a tie; without one, the middle of its quietest frame (`levels`) that
    /// does. Nil when its speech is shorter than twice that.
    static func halves(_ passage: Passage, activity: [Bool], levels: [Double], frameSamples: Int,
                       minimumSpeechSamples: Int = Int(minimumSpeechSeconds * 16_000)) -> (Passage, Passage)? {
        let frame = max(1, frameSamples)
        let speech = passage.speech
        let least = max(1, minimumSpeechSamples)
        guard speech.count >= 2 * least else { return nil }
        let middle = (speech.lowerBound + speech.upperBound) / 2
        func allowed(_ cut: Int) -> Bool { cut - speech.lowerBound >= least && speech.upperBound - cut >= least }
        // Pauses inside the speech, in frames.
        let first = speech.lowerBound / frame
        let last = min(activity.count, (speech.upperBound + frame - 1) / frame)
        var best: (length: Int, distance: Int, start: Int, end: Int)?
        var index = first
        while index < last {
            guard !activity[index] else { index += 1; continue }
            var end = index
            while end < last, !activity[end] { end += 1 }
            let cut = (index * frame + end * frame) / 2
            if allowed(cut) {
                let candidate = (length: end - index, distance: abs(cut - middle), start: index * frame,
                                 end: end * frame)
                if best == nil || candidate.length > best!.length
                    || (candidate.length == best!.length && candidate.distance < best!.distance) {
                    best = candidate
                }
            }
            index = end
        }
        let cut: Int
        var firstEnd: Int
        var secondStart: Int
        if let best {
            cut = (best.start + best.end) / 2
            firstEnd = best.start
            secondStart = best.end
        } else {
            var quietest: (level: Double, distance: Int, cut: Int)?
            for index in first..<min(last, levels.count) {
                let cut = index * frame + frame / 2
                guard allowed(cut) else { continue }
                let candidate = (level: levels[index], distance: abs(cut - middle), cut: cut)
                if quietest == nil || candidate.level < quietest!.level
                    || (candidate.level == quietest!.level && candidate.distance < quietest!.distance) {
                    quietest = candidate
                }
            }
            guard let quietest else { return nil }
            cut = quietest.cut
            firstEnd = cut
            secondStart = cut
        }
        firstEnd = max(speech.lowerBound, min(firstEnd, cut))
        secondStart = min(speech.upperBound, max(secondStart, cut))
        guard passage.range.lowerBound < cut, cut < passage.range.upperBound else { return nil }
        return (Passage(range: passage.range.lowerBound..<cut, speech: speech.lowerBound..<firstEnd),
                Passage(range: cut..<passage.range.upperBound, speech: secondStart..<speech.upperBound))
    }

    /// The probability of each of `logits`' languages among them alone (a softmax over these logits): Whisper's
    /// language detection limited to the meeting's languages. Languages without a finite logit get 0; none finite,
    /// all equal.
    static func probabilities(logits: [String: Float]) -> [String: Double] {
        let finite = logits.filter { $0.value.isFinite }
        guard let top = finite.values.max() else {
            let share = logits.isEmpty ? 0 : 1 / Double(logits.count)
            return logits.mapValues { _ in share }
        }
        let weights = finite.mapValues { exp(Double($0 - top)) }
        let sum = weights.values.reduce(0, +)
        return logits.mapValues { _ in 0 }.merging(weights.mapValues { $0 / sum }) { $1 }
    }

    /// The most probable of `languages` (in preference order) by `probabilities`: a tie, or none scored, goes to the
    /// one listed first.
    static func choice(_ probabilities: [String: Double], languages: [String]) -> String? {
        var best: (language: String, probability: Double)?
        for language in languages {
            let probability = probabilities[language] ?? 0
            if best == nil || probability > best!.probability { best = (language, probability) }
        }
        return best?.language
    }

    /// The stretches to decode: adjacent passages in the same language joined, each with its language, in order.
    /// `runs` of each planned stretch's passages on its own, in order: passages are never joined across the stretches
    /// they came from, so no run is longer than the stretch it lies in (at most `maxChunkSeconds`, the bound the
    /// decoder's window and prompt budget rely on), even when touching stretches chose one language.
    static func runs(byStretch stretches: [[(range: Range<Int>, language: String)]])
        -> [(range: Range<Int>, language: String)] {
        stretches.flatMap { runs($0) }
    }

    static func runs(_ passages: [(range: Range<Int>, language: String)]) -> [(range: Range<Int>, language: String)] {
        var out: [(range: Range<Int>, language: String)] = []
        for passage in passages where !passage.range.isEmpty {
            if let last = out.last, last.language == passage.language,
               last.range.upperBound == passage.range.lowerBound {
                out[out.count - 1].range = last.range.lowerBound..<passage.range.upperBound
            } else {
                out.append(passage)
            }
        }
        return out
    }
}
