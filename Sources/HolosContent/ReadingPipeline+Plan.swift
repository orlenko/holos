import Foundation
import HolosSynthesis

/// What identifies a reading's cache besides its text and settings: the model commit and the part plan.
extension ReadingPipeline {
    /// The model commit a reading with `voiceIdentifier` is rendered with: `NaturalVoiceModels.revision` for a natural
    /// voice, nil for an Apple voice.
    nonisolated public static func modelRevision(for voiceIdentifier: String) -> String? {
        NaturalVoiceCatalog.isNatural(voiceIdentifier) ? NaturalVoiceModels.revision : nil
    }

    /// The parts of a reading as its manifest plans them.
    nonisolated static func plan(_ parts: [ReadingScript.Part]) -> [ReadingPart] {
        parts.map { part in
            ReadingPart(index: part.index, sourceUTF16Offset: part.offset, sourceUTF16Length: part.length,
                        textSHA256: sha256(Data(part.text.utf8)), relativeAudioPath: partPath(part.index),
                        chapter: part.chapter, startsSection: part.startsSegment, status: "pending")
        }
    }

    /// Refuses to resume the reading in `directory` when it was made with another commit of the natural voices
    /// (`ReadingResumeVoice.checkRevision`); its manifest is read off the main actor. Nothing to refuse without one.
    static func refuseAnotherCommit(in directory: URL) async throws {
        if let saved = try await offMain({ ReadingResumeVoice.manifest(in: directory) }) {
            try ReadingResumeVoice.checkRevision(saved, again: "Delete it and make it again.")
        }
    }
}
