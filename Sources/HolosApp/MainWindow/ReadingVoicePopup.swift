import AppKit
import HolosSynthesis

/// A compact button opening the searchable voice picker (docs/design.md "Reading section").
///
/// Invariants:
/// 1. Only choosing a voice or Automatic calls `onChoose`; browsing and inventory refreshes do not.
/// 2. `selectedID` names an offered voice, or nil (Automatic). The caller retains a temporarily missing choice.
/// 3. An open picker receives inventory changes without losing its search or an available language filter.
@MainActor
final class ReadingVoicePopup: NSButton {
    static let automaticTitle = "Automatic"
    static let naturalHint = "Natural voices: download them in Settings › Reading"

    private(set) var catalog = ReadingVoiceList(voices: [], installed: [])
    private(set) var selectedID: String?
    var onChoose: ((String?) -> Void)?
    private let popover = NSPopover()
    private var browser: ReadingVoiceBrowser?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = Self.automaticTitle
        bezelStyle = .push
        alignment = .left
        lineBreakMode = .byTruncatingTail
        image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        imagePosition = .imageTrailing
        target = self
        action = #selector(togglePicker)
        popover.behavior = .transient
        popover.animates = false
        setAccessibilityHelp("Search voices by name, language, region, or quality")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: min(340, super.intrinsicContentSize.width), height: super.intrinsicContentSize.height)
    }

    static func fill(_ popup: ReadingVoicePopup, selecting id: String?,
                     installed: Set<NaturalVoicePack> = NaturalVoicesAppState.shared.installed,
                     voices: [VoiceDescriptor]? = nil) {
        popup.catalog = ReadingVoiceList(voices: voices ?? NativeSpeechRenderer.voices(), installed: installed)
        popup.setSelection(id)
        popup.browser?.update(catalog: popup.catalog, selectedID: popup.selectedID,
                              showNaturalHint: installed.count < NaturalVoicePack.allCases.count)
    }

    private func setSelection(_ id: String?) {
        let item = catalog.items.first { $0.id == id }
        selectedID = item?.id
        title = item.map { "\($0.name) (\($0.qualityTitle))" } ?? Self.automaticTitle
        toolTip = item?.title ?? "Automatic: best voice for the text's language. Click to search voices."
        setAccessibilityValue(item?.title ?? "Automatic: best voice for the text's language")
    }

    /// Commits only an offered voice or Automatic (invariant 1); stale rows cannot select a removed voice.
    func choose(_ id: String?) {
        guard id == nil || catalog.items.contains(where: { $0.id == id }) else { return }
        setSelection(id)
        popover.performClose(nil)
        window?.makeFirstResponder(self)
        onChoose?(selectedID)
    }

    /// The same picker content is used in both places and can be laid out offscreen by tests.
    func makeBrowser() -> ReadingVoiceBrowser {
        let content = ReadingVoiceBrowser(catalog: catalog, selectedID: selectedID,
                                         showNaturalHint: !NaturalVoicePack.allCases.allSatisfy { pack in
            catalog.items.contains { NaturalVoiceCatalog.voice(id: $0.id)?.pack == pack }
        })
        content.onChoose = { [weak self] in self?.choose($0) }
        content.onCancel = { [weak self] in
            self?.popover.performClose(nil)
            self?.window?.makeFirstResponder(self)
        }
        browser = content
        return content
    }

    @objc private func togglePicker() {
        guard window != nil else { return }
        if popover.isShown { popover.performClose(nil); return }
        let content = makeBrowser()
        popover.contentViewController = content
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        // The popover owns focus, leaving Return in the underlying Reading pane inactive while searching.
        content.view.window?.makeFirstResponder(content.search)
    }
}
