import AppKit
import Foundation
import HolosCore
import HolosTestSupport
import Synchronization
import Testing
@testable import HolosApp

/// Settings › Reading › Pronunciations (`PronunciationsSheet`) over an in-memory list; nothing is spoken or played.
@MainActor @Suite struct PronunciationsSheetTests {
    /// The list the fake store keeps.
    private final class Shared: Sendable {
        let list = Mutex(PronunciationList())
    }

    private let shared = Shared()

    private func sheet(preview: VoicePreview = VoicePreview()) -> PronunciationsSheet {
        let shared = shared
        let sheet = PronunciationsSheet(store: PronunciationsSheet.Store(
            load: { (shared.list.withLock { $0 }, nil) },
            set: { written, sayAs in
                shared.list.withLock { "\($0.set(written, sayAs: sayAs))" }
            },
            remove: { written in
                shared.list.withLock { list in "\(written.compactMap { list.remove($0)?.written })" }
            }), preview: preview)
        sheet.loadView()
        return sheet
    }

    @Test func aWordSavedIsListedAndChosenAgainToChangeItsSpelling() async throws {
        shared.list.withLock { _ = $0.set("usky", sayAs: "you sky") }
        let sheet = sheet()
        #expect(await eventually { sheet.shownWords == ["usky"] })
        sheet.writtenField.stringValue = "XIMEA"
        sheet.sayAsField.stringValue = "zay mee ah"
        sheet.save()
        #expect(await eventually { sheet.shownWords == ["usky", "XIMEA"] })
        #expect(sheet.feedbackLabel.stringValue.hasPrefix("added"))
        // A row chosen alone fills the fields; a new spelling saved changes it in place.
        sheet.choose(row: 0)
        #expect(sheet.writtenField.stringValue == "usky" && sheet.sayAsField.stringValue == "you sky")
        sheet.sayAsField.stringValue = "yoo sky"
        sheet.save()
        #expect(await eventually { shared.list.withLock { $0.entry(written: "usky")?.sayAs } == "yoo sky" })
        sheet.removeSelected()
        #expect(await eventually { sheet.shownWords == ["XIMEA"] })
    }

    @Test func blankFieldsAreNotSaved() async throws {
        let sheet = sheet()
        sheet.writtenField.stringValue = "XIMEA"
        sheet.save()
        #expect(sheet.feedbackLabel.stringValue == "Type the word as written and how to say it.")
        #expect(shared.list.withLock { $0.isEmpty })
    }

    @Test func listenSaysTheTypedSpellingWithTheReadingVoice() async throws {
        let preview = VoicePreview()
        let asked = Mutex<[String]>([])
        preview.installedPacks = { [.english] }
        // The sample is never made (nor played): the render fails once it is asked for.
        preview.renderNatural = { text, voice, _, _ in
            asked.withLock { $0.append("\(voice): \(text)") }
            throw HolosError.io("not rendered in tests")
        }
        let sheet = sheet(preview: preview)
        sheet.readingVoice = { ("pocket:en:alba", 1) }
        sheet.sayAsField.stringValue = " zay  mee ah "
        sheet.listen()
        #expect(await eventually { !asked.withLock { $0 }.isEmpty })
        #expect(asked.withLock { $0 } == ["pocket:en:alba: zay mee ah"])
    }
}
