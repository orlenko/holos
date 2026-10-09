import Foundation
import HolosCore
import HolosPocket
import HolosSynthesis
import Synchronization

// The natural voices in the `voiceislocal` tool (Sources/HolosSynthesis/README.md): the setup of the language packs.

/// `voiceislocal setup --natural-voices`.
enum NaturalVoiceSetup {
    static func run(pack: NaturalVoicePack, force: Bool) async throws {
        let progress = NaturalProgressPrinter(label: "Natural voices (\(pack.languageName))")
        try await NaturalVoiceModels.setUp(pack: pack, force: force, download: PocketSpeechBackend.download,
                                           warmUp: PocketSpeechBackend.warmUp, finish: PocketSpeechBackend.finish,
                                           verify: PocketSpeechBackend.verify,
                                           notice: { Console.error($0) },
                                           progress: progress.report)
        Console.output(NaturalVoiceModels.readyMessage(pack))
        Console.output(NaturalVoiceModels.creditsLine)
    }
}

/// Prints "<label>: N%" to stderr at each new 5 % step (the app's Settings row shows the last line).
private final class NaturalProgressPrinter: Sendable {
    private let lastStep = Mutex(-1)
    private let label: String

    init(label: String) { self.label = label }

    var report: @Sendable (Double) -> Void {
        { [self] fraction in
            guard fraction.isFinite else { return }
            let step = Int(min(1, max(0, fraction)) * 20)
            let isNew = lastStep.withLock { last in
                guard step > last else { return false }
                last = step
                return true
            }
            if isNew { Console.error("\(label): \(step * 5)%") }
        }
    }
}
