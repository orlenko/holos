import HolosCore

/// A stage's actual progress. The fraction describes this step, never an estimate of remaining meeting time.
public struct MeetingProgressPresentation: Sendable, Equatable {
    public let title: String
    public let fraction: Double?

    public init(_ progress: PostProcessingProgress) {
        let stageTitle = switch progress.stage {
        case .deepTranscription, .languages, .transcript: "Transcribing"
        case .diarize, .recognize, .align: "Identifying speakers"
        case .echo: "Removing echo"
        case .render: "Preparing audio"
        default: "Processing"
        }
        let track = switch progress.track {
        case "mic": "microphone"
        case "system": "computer audio"
        default: ""
        }
        title = progress.stage != .deepTranscription && !track.isEmpty ? "\(stageTitle) (\(track))" : stageTitle
        fraction = progress.fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    }

    public var percent: Int? { fraction.map { Int(($0 * 100).rounded(.down)) } }
}
