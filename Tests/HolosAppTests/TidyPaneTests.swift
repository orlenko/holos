import AppKit
import Foundation
import HolosCore
import HolosDictation
import HolosMeeting
import Testing
@testable import HolosApp

/// The Tidy Up section (docs/design.md "Tidy Up") with a fake tool: nothing runs, nothing is copied unless Copy is
/// pressed. Invented text.
@MainActor
struct TidyPaneTests {
    /// What the fake actions saw.
    final class Calls {
        var tidied: [String] = []
        var copied: [String] = []
        var installs: [URL?] = []
        var completion: (@MainActor (CommandResult<TidyCommand.Outcome>) -> Void)?
    }

    static func actions(status: DeepModelStatus, calls: Calls = Calls(), last: String? = nil) -> TidyPane.Actions {
        TidyPane.Actions(
            tidy: { text, completion in
                calls.tidied.append(text)
                calls.completion = completion
                return .success(CommandHandle())
            },
            install: { file, _, _ in
                calls.installs.append(file)
                return true
            },
            remove: { _ in true },
            lastDictation: { last },
            copy: { text in
                calls.copied.append(text)
                return true
            },
            modelStatus: { status })
    }

    static func views<T: NSView>(_ pane: TidyPane, _ type: T.Type) -> [T] {
        MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? T }
    }

    static func button(_ pane: TidyPane, _ title: String) throws -> NSButton {
        try #require(views(pane, NSButton.self).first { $0.title == title })
    }

    static func labels(_ pane: TidyPane) -> [String] { views(pane, NSTextField.self).map(\.stringValue) }

    @Test(arguments: [CGFloat(400), 900])
    func theEditorFillsThePanelUntilTidyingOpensTwoEqualColumns(width: CGFloat) throws {
        let pane = TidyPane(actions: Self.actions(status: .installed))
        let input = try #require(pane.preferredFirstResponder?.enclosingScrollView)
        let result = try #require(Self.views(pane, NSTextView.self).first { !$0.isEditable }?.enclosingScrollView)
        pane.load("One sentence. In two parts.")
        pane.view.setFrameSize(NSSize(width: width, height: 700))
        pane.view.layoutSubtreeIfNeeded()
        #expect(!input.isHiddenOrHasHiddenAncestor)
        #expect(input.frame.width > width - 50)
        #expect(input.frame.height > 600)
        #expect(result.isHiddenOrHasHiddenAncestor)

        try Self.button(pane, "Tidy Up").performClick(nil)
        pane.view.layoutSubtreeIfNeeded()
        #expect(!result.isHiddenOrHasHiddenAncestor)
        #expect(abs(input.frame.width - result.frame.width) <= 1)
        #expect(input.convert(input.bounds, to: pane.view).maxX < result.convert(result.bounds, to: pane.view).minX)
        let spinner = try #require(Self.views(pane, NSProgressIndicator.self).first)
        #expect(spinner.isIndeterminate && !spinner.isHiddenOrHasHiddenAncestor)

        try Self.button(pane, "Cancel").performClick(nil)
        pane.view.layoutSubtreeIfNeeded()
        #expect(result.isHiddenOrHasHiddenAncestor)
        #expect(input.frame.width > width - 50)
    }

    @Test func aResultShowsRemovedWordsStruckAndCopyIsOnlyOnThePress() throws {
        let calls = Calls()
        let pane = TidyPane(actions: Self.actions(status: .installed, calls: calls))
        let original = "We went out. And then. We came back home."
        pane.load(original)
        try Self.button(pane, "Tidy Up").performClick(nil)
        #expect(calls.tidied == [original])
        let edited = "We went out and then came back home."
        let outcome = TidyCommand.Outcome(engine: .qwen, text: edited, parts: [
            TextTidier.Part(original: original, text: edited, separator: "", kept: nil),
        ], changes: WordChanges.between(original, edited))
        let completion = try #require(calls.completion)
        completion(CommandResult(code: 0, outcome: outcome))
        #expect(calls.copied.isEmpty, "Nothing is copied until Copy Tidied Text is pressed.")

        let result = try #require(Self.views(pane, NSTextView.self).first { !$0.isEditable })
        let storage = try #require(result.textStorage)
        #expect(storage.string == "We went out and then We came back home.", "The removed word shows in place.")
        let struck = (storage.string as NSString).range(of: " We")
        #expect(storage.attribute(.strikethroughStyle, at: struck.location + 1, effectiveRange: nil) != nil)

        try Self.button(pane, "Copy Tidied Text").performClick(nil)
        #expect(calls.copied == [edited], "Copy takes the tidied text without the struck-through words.")
    }

    @Test func aTextThatWasNotTidiedSaysWhyAndOffersNoCopy() throws {
        let calls = Calls()
        let pane = TidyPane(actions: Self.actions(status: .notInstalled, calls: calls))
        pane.load("hello there")
        try Self.button(pane, "Tidy Up").performClick(nil)
        let outcome = TidyCommand.Outcome(engine: .apple, text: "hello there", parts: [
            TextTidier.Part(original: "hello there", text: "hello there", separator: "",
                            kept: "the model left out too many words"),
        ], changes: [])
        let completion = try #require(calls.completion)
        completion(CommandResult(code: 1, outcome: outcome))
        let result = try #require(Self.views(pane, NSTextView.self).first { !$0.isEditable })
        #expect(!result.isHiddenOrHasHiddenAncestor)
        #expect(result.string == "The text was left as it was: the model left out too many words.")
        #expect(!Self.views(pane, NSProgressIndicator.self).contains { !$0.isHiddenOrHasHiddenAncestor })
        #expect(try !Self.button(pane, "Copy Tidied Text").isEnabled)
    }

    @Test func theModelLineOffersQwenUntilItIsInstalled() throws {
        let calls = Calls()
        let pane = TidyPane(actions: Self.actions(status: .notInstalled, calls: calls))
        try Self.button(pane, "Model Options…").performClick(nil)
        #expect(try !Self.button(pane, "Install Qwen…").isHidden)
        #expect(try Self.button(pane, "Remove Qwen…").isHidden)
        try Self.button(pane, "Install Qwen…").performClick(nil)
        #expect(calls.installs == [nil])

        let installed = TidyPane(actions: Self.actions(status: .installed))
        try Self.button(installed, "Model Options…").performClick(nil)
        #expect(try Self.button(installed, "Install Qwen…").isHidden)
        #expect(try !Self.button(installed, "Remove Qwen…").isHidden)
    }

    @Test func lastDictationFillsTheBoxOrSaysThereIsNone() throws {
        let pane = TidyPane(actions: Self.actions(status: .installed, last: "lunch at noon. with Sam"))
        try Self.button(pane, "Last Dictation").performClick(nil)
        let box = try #require(Self.views(pane, NSTextView.self).first { $0.isEditable })
        #expect(box.string == "lunch at noon. with Sam")

        let none = TidyPane(actions: Self.actions(status: .installed, last: nil))
        try Self.button(none, "Last Dictation").performClick(nil)
        #expect(Self.labels(none).contains { $0.hasPrefix("No dictation since Voice is Local started.") })
    }

    @Test func aTextOverOneMegabyteIsRefusedBeforeAnythingRuns() throws {
        let calls = Calls()
        let pane = TidyPane(actions: Self.actions(status: .installed, calls: calls))
        pane.load(String(repeating: "word ", count: 210_000))
        try Self.button(pane, "Tidy Up").performClick(nil)
        #expect(calls.tidied.isEmpty)
        let result = try #require(Self.views(pane, NSTextView.self).first { !$0.isEditable })
        #expect(result.string.hasPrefix("The text is longer than Tidy Up takes"))
    }

    @Test func historysTidyUpWhileATidyUpRunsSaysSoAndKeepsTheBox() throws {
        let calls = Calls()
        let pane = TidyPane(actions: Self.actions(status: .installed, calls: calls))
        pane.load("first text")
        try Self.button(pane, "Tidy Up").performClick(nil)
        pane.load("second text")
        let box = try #require(Self.views(pane, NSTextView.self).first { $0.accessibilityLabel() == "Text to tidy" })
        #expect(box.string == "first text")
        #expect(Self.labels(pane).contains("A tidy-up is running. Cancel it to tidy another text."))
        try Self.button(pane, "Cancel").performClick(nil)
        #expect(try Self.button(pane, "Tidy Up").isEnabled)
    }

    @Test func tidyUpWaitsWhileQwenInstalls() throws {
        let pane = TidyPane(actions: Self.actions(status: .notInstalled))
        try Self.button(pane, "Model Options…").performClick(nil)
        try Self.button(pane, "Install Qwen…").performClick(nil)
        #expect(try !Self.button(pane, "Tidy Up").isEnabled)
    }

    @Test func theEditCannotBeSelectedSoACopyFromItCannotTakeRemovedWords() throws {
        let pane = TidyPane(actions: Self.actions(status: .installed))
        let result = try #require(Self.views(pane, NSTextView.self).first { $0.accessibilityLabel() == "Tidied text" })
        #expect(!result.isSelectable)
    }
}
