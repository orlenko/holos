import AppKit
import HolosCore
import HolosDesktop
import HolosSynthesis

/// The main window's Settings section (it replaces the Setup window): cards for General, Permissions, Dictation,
/// Meetings, Reading, and Dictation history, and a way back to the Setup Assistant. It shows `SetupState`, which the app delegate refreshes
/// every second while the section is on screen (TCC has no change notification), and reports each change through its
/// callbacks. The sidebar lists the cards as chapters (`show(chapter:animated:)`, `onChapterChange`), and a search
/// field above the page shows only the settings that match (`SettingsSearch`).
@MainActor
final class SettingsPane: NSViewController, MainSectionContent, NSSearchFieldDelegate {
    private enum Mark { case done, pending, problem }
    private struct Row {
        let icon: NSImageView
        let title: NSTextField
        let detail: NSTextField
        let button: NSButton
        /// A link under the button; only permission rows show it (System Settings…).
        let link: NSButton
        let grid: NSGridView
        /// What `set` last asked for; shown only while the row is (`applyRowButtons`).
        var wantsButton = false
        var wantsLink = false
    }

    /// One setting the search finds (`SettingsSearch`): a row of a grid, or views of a card's stack.
    private struct SearchItem {
        /// Nil for the Setup Assistant footer.
        let chapter: SettingsChapter?
        let entry: SettingsSearch.Entry
        /// A status row's detail line, or the reading folder: what it says now is searched as its caption. Only
        /// `setSearched` changes it.
        var liveCaption: NSTextField?
        /// Its title as shown now, when it changes at run time (a status row's title, a checkbox that names its
        /// examples or why it is unavailable); `setSearched` changes it.
        var liveTitle: (@MainActor () -> String)?
        /// The card's views it is made of, hidden when it does not match.
        var views: [NSView] = []
        /// Its grid, and a view in its row: the row is hidden when it does not match.
        var grid: NSGridView?
        var gridAnchor: NSView?
        /// Views shown along with it: the option it is indented under.
        var context: [NSView] = []
        /// A status row, which its state can hide (Input Monitoring).
        var action: SetupAction?
        /// What Return focuses, when it takes the focus.
        var focus: NSView?
    }

    struct Callbacks {
        var perform: (SetupAction) -> Void
        var opacity: (Double) -> Void
        var language: (String) -> Void
        var shortcut: (HotkeyChoice) -> Void
        var retention: (HistoryRetention) -> Void
        var appearance: (AppearanceChoice) -> Void
    }

    private let callbacks: Callbacks
    private let openAtLaunchToggle = NSButton(checkboxWithTitle: "Open the Voice is Local window when it starts",
                                              target: nil, action: nil)
    private let appearanceControl = NSSegmentedControl(labels: AppearanceChoice.allCases.map(\.title),
                                                       trackingMode: .selectOne, target: nil, action: nil)
    private let fillerToggle = NSButton(checkboxWithTitle: "Remove filler words", target: nil, action: nil)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shortcutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let retentionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var shownLocaleGroups: [[String]]?
    private let previewToggle = NSButton(checkboxWithTitle: "Show the dictation preview while dictating",
                                         target: nil, action: nil)
    private static let aiFixTitle = "Fix misheard words with Apple Intelligence (on-device)"
    private let aiFixToggle = NSButton(checkboxWithTitle: aiFixTitle, target: nil, action: nil)
    private let spokenCodeToggle = NSButton(checkboxWithTitle: "Write spoken paths and commands as code",
                                            target: nil, action: nil)
    private let spokenCodeBackticksToggle = NSButton(checkboxWithTitle: "Wrap them in backticks (never in a terminal)",
                                                     target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 0.85, minValue: 0.3, maxValue: 1.0, target: nil, action: nil)
    private let opacityValue = NSTextField(labelWithString: "")
    private let recordSystemAudioToggle = NSButton(
        checkboxWithTitle: "Record the computer's audio (system sound) in meetings", target: nil, action: nil)
    private let screenCaptureToggle = NSButton(checkboxWithTitle: MeetingScreenText.settingTitle, target: nil, action: nil)
    private let deepTranscriptionToggle = NSButton(
        checkboxWithTitle: "Deep transcription after meetings: transcribe them again with Whisper on this Mac",
        target: nil, action: nil)
    private static let meetingSummariesTitle = "Title and summarize meetings with Apple Intelligence (on-device)"
    private let meetingSummariesToggle = NSButton(checkboxWithTitle: meetingSummariesTitle, target: nil, action: nil)
    private let readingVoicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let readingSpeedSlider = NSSlider(value: ReadingSpeed.standard, minValue: ReadingSpeed.range.lowerBound,
                                              maxValue: ReadingSpeed.range.upperBound, target: nil, action: nil)
    private let readingSpeedLabel = NSTextField(labelWithString: "")
    /// The natural voice packs installed when the reading card's voice menu was last filled.
    private var shownNaturalVoices: Set<NaturalVoicePack> = []
    private var readingFolderDetail: NSTextField?
    private let historyAudioToggle = NSButton(
        checkboxWithTitle: "Keep the audio of dictations (for Run Again)", target: nil, action: nil)
    private let historyAudioUsage = SettingsPane.note("")
    private var rows: [SetupAction: Row] = [:]
    /// Status rows their state hides (Input Monitoring until macOS refuses the hotkey tap).
    private var stateHidden: Set<SetupAction> = []
    private static let textWidth: CGFloat = 360

    // Chapters and search.
    /// What the sidebar marks: the chapter at the top, on each scroll by the user (not while `show(chapter:)`
    /// scrolls) and after a search or Return moved the page, repeats included, so the sidebar can leave the Settings
    /// row for General; nil, the Settings row, while a search is open.
    var onChapterChange: ((SettingsChapter?) -> Void)?
    /// The chapter the page shows: the one at the top, or the one chosen.
    private(set) var currentChapter = SettingsChapter.general
    /// The chapter the user chose in the sidebar (or went to with Return) while its card stays in view: at the end of
    /// the page, it stays marked (`SettingsChapterTracking`).
    private var chosenChapter: SettingsChapter?
    private let search = NSSearchField()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var sections: [SettingsChapter: NSView] = [:]
    private var grids: [NSGridView] = []
    /// Each grid's width, the card's: off while the search hides the grid whole, whose empty width would squeeze
    /// every card to it.
    private var gridWidths: [ObjectIdentifier: NSLayoutConstraint] = [:]
    private let noMatches = NSTextField(wrappingLabelWithString: "")
    private var items: [SearchItem] = []
    /// The items that match the query, best first; nil while there is no query.
    private var matches: [Int]?
    /// The page is scrolling on its own (`show(chapter:)`, a search, Return): the scroll does not move the sidebar
    /// until the latest such scroll ends.
    private var scrollGeneration = SettingsScrollGeneration()
    /// The setting Return went to, outlined for a moment.
    private var highlight: NSView?
    /// The best match, outlined while the search lasts.
    private var outline: SettingsHighlightView?

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
        super.init(nibName: nil, bundle: nil)
        view = makeContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    /// The search field above the scrolling page of cards.
    private func makeContent() -> NSView {
        noMatches.font = .systemFont(ofSize: 13)
        noMatches.textColor = .secondaryLabelColor
        noMatches.isHidden = true
        for checkbox in [openAtLaunchToggle, fillerToggle, previewToggle, aiFixToggle, spokenCodeToggle,
                         spokenCodeBackticksToggle, recordSystemAudioToggle, screenCaptureToggle,
                         deepTranscriptionToggle, meetingSummariesToggle, historyAudioToggle] {
            Self.wrapsTitle(checkbox)
        }
        let stack = NSStackView(views: [
            noMatches, generalCard(), permissionsCard(), dictationCard(), meetingsCard(), readingCard(), historyCard(),
            assistantFooter(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        // The cards fill the page up to 760 points. Below the window's own size (NSWindow holds it at 500): above
        // it, a page wider than 816 points pulled the window's content in to fit, leaving the rest of the window
        // empty.
        let fill = stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28)
        fill.priority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 10)

        search.placeholderString = "Search settings"
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.delegate = self
        search.setAccessibilityLabel("Search settings")
        search.toolTip = "Return goes to the best match; Escape clears the search."
        search.translatesAutoresizingMaskIntoConstraints = false
        let searchWidth = search.widthAnchor.constraint(equalToConstant: 340)
        searchWidth.priority = .defaultHigh

        // A hairline where the page scrolls under the search field; one point high (`hairline`): in some windows a
        // separator without a height took all the page's.
        let separator = NSBox.hairline()

        let root = NSView()
        root.addSubview(search)
        root.addSubview(separator)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            search.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
            searchWidth,
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            separator.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -28),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            fill,
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28),
        ])
        return root
    }

    /// Settings › General: whether the window opens at launch, and the appearance of every window.
    private func generalCard() -> NSView {
        openAtLaunchToggle.target = self
        openAtLaunchToggle.action = #selector(buttonPressed(_:))
        openAtLaunchToggle.tag = SetupAction.toggleOpenWindowAtLaunch.rawValue
        let launchNote = Self.note("""
            Closing the window keeps Voice is Local running in the menu bar; Quit in its menu, or ⌘Q, quits it. \
            When this is off, the app starts in the menu bar only (Open Voice is Local, ⌘0, opens the window), and \
            Settings still opens while dictation is off.
            """)
        let launch = NSStackView(views: [openAtLaunchToggle, launchNote])
        launch.orientation = .vertical
        launch.alignment = .leading
        launch.spacing = 4
        addItem(.general, openAtLaunchToggle.title, caption: launchNote.stringValue,
                keywords: ["launch", "startup", "login", "menu bar", "quit"], views: [launch],
                focus: openAtLaunchToggle)

        let grid = makeGrid()
        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChosen(_:))
        appearanceControl.segmentDistribution = .fillEqually
        appearanceControl.setAccessibilityLabel("Appearance")
        addControlRow(.general, "circle.lefthalf.filled", "Appearance",
                      "Every Voice is Local window and the dictation preview; System follows macOS",
                      keywords: ["dark mode", "light mode", "theme", "colour", "color"],
                      control: appearanceControl, to: grid)
        return card(.general, [launch, grid], widths: [launch, launchNote, grid])
    }

    private func permissionsCard() -> NSView {
        let grid = makeGrid()
        let keywords: [SetupAction: [String]] = [
            .microphone: ["mic", "privacy", "permission", "voice"],
            .accessibility: ["insert text", "typing", "privacy", "permission", "allow"],
            .systemAudio: ["screen recording", "computer audio", "system sound", "privacy", "permission", "allow"],
            .inputMonitoring: ["keyboard", "hotkey", "shortcut", "privacy", "permission", "allow"],
        ]
        for (action, title) in [(SetupAction.microphone, "Microphone"), (.accessibility, "Accessibility"),
                                (.systemAudio, "System audio"), (.inputMonitoring, "Input Monitoring")] {
            addRow(action, title, to: grid)
            addRowItem(.permissions, action, keywords: keywords[action] ?? [])
        }
        setRowHidden(.inputMonitoring, true)  // until macOS refuses the hotkey tap (`update`)
        let note = Self.note("""
            This updates on its own while you change System Settings. After rebuilding Voice is Local, macOS can \
            keep an old entry that looks switched on but no longer matches the app: select Voice is Local in that \
            list, remove it with –, then click Allow… here to add it again. An entry named Holos is this app from \
            before it was renamed; remove it the same way. Allow… only asks macOS (its prompt appears once); \
            System Settings… only opens the page.
            """)
        addItem(.permissions, "", caption: note.stringValue, keywords: [], views: [note], focus: nil)
        return card(.permissions, [grid, note], widths: [grid, note])
    }

    private func dictationCard() -> NSView {
        let grid = makeGrid()
        addRow(.dictation, "Dictation", to: grid)
        addRowItem(.dictation, .dictation, keywords: ["turn on", "turn off", "enable", "start"])

        shortcutPopup.target = self
        shortcutPopup.action = #selector(shortcutChosen(_:))
        for (choice, title) in [(HotkeyChoice.rightOption, "Right Option"),
                                (.controlOptionSpace, "Control–Option–Space")] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = choice.rawValue
            shortcutPopup.menu?.addItem(item)
        }
        shortcutPopup.setAccessibilityLabel("Hold-to-talk shortcut")
        addControlRow(.dictation, "keyboard", "Hold-to-talk shortcut", "Hold it, wait for Listening, speak, release",
                      keywords: ["hotkey", "key", "right option", "control option space", "push to talk"],
                      control: shortcutPopup, to: grid)

        languagePopup.target = self
        languagePopup.action = #selector(languageChosen(_:))
        languagePopup.setAccessibilityLabel("Dictation language")
        addControlRow(.dictation, "globe", "Dictation language", "Used from the next dictation",
                      keywords: ["locale", "english", "french", "français", "langue"], control: languagePopup, to: grid)
        addRow(.assets, "Speech model", to: grid)
        addRowItem(.dictation, .assets, title: "Speech model",
                   keywords: ["download", "install", "recognition", "asset"])

        for (toggle, action) in [(fillerToggle, SetupAction.toggleFillers), (aiFixToggle, .toggleAIFix),
                                 (previewToggle, .togglePreview), (spokenCodeToggle, .toggleSpokenCode),
                                 (spokenCodeBackticksToggle, .toggleSpokenCodeBackticks)] {
            toggle.target = self
            toggle.action = #selector(buttonPressed(_:))
            toggle.tag = action.rawValue
        }
        spokenCodeToggle.toolTip = "“scripts slash restart dash app dot S H” is written scripts/restart-app.sh, “slash Q C” /qc. Apple's on-device model finds them when it is available; a token is kept only when every symbol in it was said, and the rest of the text never changes."
        spokenCodeBackticksToggle.toolTip = "Writes `scripts/restart-app.sh` with backticks. A terminal always gets the path itself."
        // Indented under the option it belongs to.
        let backticksRow = NSStackView(views: [spokenCodeBackticksToggle])
        backticksRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        previewToggle.toolTip = "When off, text just streams into the field. Problems that need you (text that could not be written, a failed dictation) are always shown."
        aiFixToggle.toolTip = "Each phrase is checked by Apple's on-device model before it is typed, which adds about half a second. Only small fixes are kept; History and Copy Original have the text as heard."

        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.isContinuous = true
        opacitySlider.setAccessibilityLabel("Dictation preview opacity")
        let opacityWidth = opacitySlider.widthAnchor.constraint(equalToConstant: 200)
        opacityWidth.priority = .defaultLow  // narrower in a narrow window
        opacityWidth.isActive = true
        opacitySlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        opacityValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        opacityValue.textColor = .secondaryLabelColor
        let opacityRow = NSStackView(views: [NSTextField(labelWithString: "Preview opacity"), opacitySlider,
                                             opacityValue])
        opacityRow.spacing = 10
        opacityRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        addItem(.dictation, "Remove filler words", caption: "", keywords: ["um", "uh", "euh", "fillers", "clean up"],
                views: [fillerToggle], focus: fillerToggle, titledBy: fillerToggle)
        addItem(.dictation, spokenCodeToggle.title, caption: spokenCodeToggle.toolTip ?? "",
                keywords: ["code", "path", "file", "command", "terminal", "programming"],
                views: [spokenCodeToggle], focus: spokenCodeToggle)
        addItem(.dictation, spokenCodeBackticksToggle.title, caption: spokenCodeBackticksToggle.toolTip ?? "",
                keywords: ["backtick", "markdown", "code"], views: [backticksRow], focus: spokenCodeBackticksToggle,
                context: [spokenCodeToggle])
        addItem(.dictation, Self.aiFixTitle, caption: aiFixToggle.toolTip ?? "",
                keywords: ["ai", "correct", "mistakes", "on-device", "model"], views: [aiFixToggle], focus: aiFixToggle,
                titledBy: aiFixToggle)
        addItem(.dictation, previewToggle.title, caption: previewToggle.toolTip ?? "",
                keywords: ["overlay", "panel", "hud", "show text"], views: [previewToggle], focus: previewToggle)
        addItem(.dictation, "Preview opacity", caption: "", keywords: ["transparency", "transparent", "see through"],
                views: [opacityRow], focus: opacitySlider, context: [previewToggle])
        return card(.dictation, [grid, fillerToggle, spokenCodeToggle, backticksRow, aiFixToggle, previewToggle,
                                 opacityRow], widths: [grid])
    }

    private func meetingsCard() -> NSView {
        recordSystemAudioToggle.target = self
        recordSystemAudioToggle.action = #selector(buttonPressed(_:))
        recordSystemAudioToggle.tag = SetupAction.toggleRecordSystemAudio.rawValue
        screenCaptureToggle.target = self
        screenCaptureToggle.action = #selector(buttonPressed(_:))
        screenCaptureToggle.tag = SetupAction.toggleMeetingScreenCapture.rawValue
        let screenDetail = Self.note(MeetingScreenText.settingCaption)
        let detail = Self.note("""
            On: meetings record your microphone and everything the Mac plays, and speakers are labelled on both. \
            Off: meetings record the microphone only.
            """)
        deepTranscriptionToggle.target = self
        deepTranscriptionToggle.action = #selector(buttonPressed(_:))
        deepTranscriptionToggle.tag = SetupAction.toggleDeepTranscription.rawValue
        let deepDetail = Self.note("""
            After a meeting is saved, its audio is transcribed again with a larger model, prompted with your word \
            list and people's names, and the result replaces the transcript (the one before is kept). It runs on AC \
            power, one meeting at a time; on battery it waits for the power adapter. Right-click a meeting for Make \
            Final Transcript Now or Cancel. It is tuned for English meetings; meetings in other languages, or in \
            several, keep their transcript.
            """)
        meetingSummariesToggle.target = self
        meetingSummariesToggle.action = #selector(buttonPressed(_:))
        meetingSummariesToggle.tag = SetupAction.toggleMeetingSummaries.rawValue
        let summariesDetail = Self.note("""
            Once a meeting's transcript is final, Apple's on-device model writes a short title and a summary for the \
            Meetings list, with key points and action items in the transcript files. Nothing leaves this Mac. A name \
            you give a meeting is never replaced. Right-click a meeting for Summarize Again.
            """)
        let grid = makeGrid()
        addRow(.speakerModels, "Speaker labels", to: grid)
        addRow(.deepTranscriptionModel, "Final transcript", to: grid)
        addRow(.people, "Remember voices", to: grid)
        set(.people, .pending, "On for new installs: Voice is Local learns the voices of people you name, on this Mac, "
            + "and suggests them in later meetings. Turn it off or forget voices in People.", button: "Open People")
        rows[.people]?.icon.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
        rows[.people]?.icon.contentTintColor = .secondaryLabelColor

        addItem(.meetings, recordSystemAudioToggle.title, caption: detail.stringValue,
                keywords: ["system sound", "computer audio", "calls", "zoom", "video"],
                views: [recordSystemAudioToggle, detail], focus: recordSystemAudioToggle)
        addItem(.meetings, MeetingScreenText.settingTitle, caption: screenDetail.stringValue,
                keywords: ["screen", "screenshot", "display", "displays", "monitor", "slides", "capture"],
                views: [screenCaptureToggle, screenDetail], focus: screenCaptureToggle)
        addItem(.meetings, deepTranscriptionToggle.title, caption: deepDetail.stringValue,
                keywords: ["whisper", "final transcript", "accuracy", "transcribe again"],
                views: [deepTranscriptionToggle, deepDetail], focus: deepTranscriptionToggle)
        addItem(.meetings, Self.meetingSummariesTitle, caption: summariesDetail.stringValue,
                keywords: ["summary", "summaries", "titles", "action items", "key points", "ai"],
                views: [meetingSummariesToggle, summariesDetail], focus: meetingSummariesToggle,
                titledBy: meetingSummariesToggle)
        addRowItem(.meetings, .speakerModels, keywords: ["diarization", "speakers", "who spoke", "install"])
        addRowItem(.meetings, .deepTranscriptionModel, keywords: ["whisper", "model", "download"])
        addRowItem(.meetings, .people, keywords: ["people", "voices", "names", "voice profiles"])
        return card(.meetings, [recordSystemAudioToggle, detail, screenCaptureToggle, screenDetail,
                                deepTranscriptionToggle, deepDetail, meetingSummariesToggle, summariesDetail, grid],
                    widths: [detail, screenDetail, deepDetail, summariesDetail, grid])
    }

    /// Settings › Reading: what new readings in the Reading section start with, and where their files go.
    private func readingCard() -> NSView {
        let grid = makeGrid()
        readingVoicePopup.target = self
        readingVoicePopup.action = #selector(readingVoiceChosen(_:))
        readingVoicePopup.setAccessibilityLabel("Default reading voice")
        addControlRow(.reading, "person.wave.2", "Voice", "Natural voices sound best; download them below. Apple's "
                      + "Premium voices come next; add them in System Settings › Accessibility › Spoken Content",
                      keywords: ["reading voice", "text to speech", "tts", "premium", "siri", "natural"],
                      control: readingVoicePopup, to: grid)

        readingSpeedSlider.numberOfTickMarks = 7
        readingSpeedSlider.allowsTickMarkValuesOnly = true
        readingSpeedSlider.target = self
        readingSpeedSlider.action = #selector(readingSpeedChanged(_:))
        readingSpeedSlider.setAccessibilityLabel("Default reading speed")
        readingSpeedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        readingSpeedLabel.textColor = .secondaryLabelColor
        let speed = NSStackView(views: [readingSpeedSlider, readingSpeedLabel])
        speed.spacing = 8
        addControlRow(.reading, "gauge.with.needle", "Speed", "0.8× to 1.4× of the voice's normal pace",
                      keywords: ["rate", "pace", "faster", "slower", "reading speed"], control: speed,
                      focus: readingSpeedSlider, to: grid)

        addRow(.naturalVoicesEnglish, "Natural voices (English)", to: grid)
        addRow(.naturalVoicesFrench, "Natural voices (French)", to: grid)
        addRowItem(.reading, .naturalVoicesEnglish,
                   keywords: ["natural", "neural", "pocket", "kyutai", "alba", "download", "voices"])
        addRowItem(.reading, .naturalVoicesFrench,
                   keywords: ["natural", "neural", "pocket", "kyutai", "estelle", "french", "download"])

        let (text, _, detail) = Self.labels("Save audio files in")
        readingFolderDetail = detail
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseReadingFolder))
        choose.bezelStyle = .push
        choose.setAccessibilityLabel("Choose the folder audio files are saved in")
        grid.addRow(with: [icon, text, choose])
        finishRow(in: grid)
        items.append(SearchItem(chapter: .reading, entry: SettingsSearch.Entry(
            title: "Save audio files in", keywords: ["folder", "location", "output", "music", "files"]),
            liveCaption: detail, grid: grid, gridAnchor: icon, focus: choose))

        let note = Self.note("""
            Readings are made on this Mac: nothing is uploaded, and the only thing fetched is the page you paste. \
            While a reading is made, its parts are kept in Application Support so it can continue after a stop.
            """)
        addItem(.reading, "", caption: note.stringValue, keywords: [], views: [note], focus: nil)
        refreshReadingCard()
        return card(.reading, [grid, note], widths: [grid, note])
    }

    /// Shows Settings › Reading as saved (and the voices installed now).
    private func refreshReadingCard() {
        ReadingVoicePopup.fill(readingVoicePopup, selecting: ReadingPreferences.voice)
        readingSpeedSlider.doubleValue = ReadingPreferences.speed
        readingSpeedLabel.stringValue = ReadingSpeed.label(readingSpeedSlider.doubleValue)
        if let readingFolderDetail { setSearched(readingFolderDetail, ReadingPreferences.folderText) }
    }

    /// Sets a searched text that changes at run time: a caption (an item's `liveCaption`: a status row's detail
    /// line, the reading folder) or a title (its `liveTitle`: "Speech model: French (Canada)"). The one way they
    /// change, so an open search runs again when one does (`refreshSearch`); during `update`, once at its end.
    private func setSearched(_ field: NSTextField, _ text: String) {
        guard field.stringValue != text else { return }
        field.stringValue = text
        searchedTextChanged()
    }

    /// A checkbox's searched title ("Remove filler words (um, uh)").
    private func setSearched(_ button: NSButton, title: String) {
        guard button.title != title else { return }
        button.title = title
        searchedTextChanged()
    }

    private func searchedTextChanged() {
        guard matches != nil else { return }
        if updating {
            searchedTextChangedInUpdate = true
        } else {
            refreshSearch()
        }
    }

    /// `update` is running: a searched text's change runs the search again once, at its end.
    private var updating = false
    private var searchedTextChangedInUpdate = false

    func sectionDidShow() {
        refreshReadingCard()
    }

    @objc private func readingVoiceChosen(_ sender: NSPopUpButton) {
        ReadingPreferences.voice = sender.selectedItem?.representedObject as? String
    }

    @objc private func readingSpeedChanged(_ sender: NSSlider) {
        readingSpeedLabel.stringValue = ReadingSpeed.label(sender.doubleValue)
        ReadingPreferences.speed = sender.doubleValue
    }

    @objc private func chooseReadingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = ReadingPreferences.folder
        panel.message = "Choose the folder new readings' audio files are saved in."
        panel.prompt = "Choose"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            MainActor.assumeIsolated {
                ReadingPreferences.folder = folder
                self?.refreshReadingCard()
            }
        }
    }

    private func historyCard() -> NSView {
        let grid = makeGrid()
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChosen(_:))
        for retention in HistoryRetention.allCases {
            let item = NSMenuItem(title: retention.title, action: nil, keyEquivalent: "")
            item.representedObject = retention.rawValue
            retentionPopup.menu?.addItem(item)
        }
        retentionPopup.setAccessibilityLabel("Keep dictations")
        addControlRow(.history, "clock.arrow.circlepath", "Keep dictations", "Off stops recording new dictations",
                      keywords: ["retention", "days", "forever", "history", "privacy"],
                      control: retentionPopup, to: grid)
        addRow(.clearHistory, "History", to: grid)
        addRowItem(.history, .clearHistory, keywords: ["clear history", "delete", "erase", "privacy"])
        historyAudioToggle.target = self
        historyAudioToggle.action = #selector(buttonPressed(_:))
        historyAudioToggle.tag = SetupAction.toggleHistoryAudio.rawValue
        historyAudioToggle.toolTip = "Keeps the microphone audio of each dictation History records, so Run Again can "
            + "recognize it again after you change a correction or a setting. It is deleted with its dictation."
        let audio = NSStackView(views: [historyAudioToggle, historyAudioUsage])
        audio.orientation = .vertical
        audio.alignment = .leading
        audio.spacing = 2
        historyAudioUsage.setAccessibilityLabel("Dictation audio disk use")
        let note = Self.note("""
            History keeps each dictation's text, the text as heard, the app, and the language, and, when the box \
            above is on, its audio, only on this Mac. Nothing is copied to the clipboard unless you choose Copy. \
            Meetings are kept until you delete them in Meetings.
            """)
        addItem(.history, historyAudioToggle.title, caption: historyAudioToggle.toolTip ?? "",
                keywords: ["audio", "run again", "disk", "storage", "recordings"], views: [audio],
                focus: historyAudioToggle)
        addItem(.history, "", caption: note.stringValue, keywords: [], views: [note], focus: nil)
        return card(.history, [grid, audio, note], widths: [grid, note])
    }

    private func assistantFooter() -> NSView {
        let button = NSButton(title: "Run Setup Assistant…", target: self, action: #selector(buttonPressed(_:)))
        button.bezelStyle = .push
        button.tag = SetupAction.setupAssistant.rawValue
        let text = Self.note("Walks through permissions, the speech model, and meetings again, step by step.")
        let stack = NSStackView(views: [button, text])
        stack.spacing = 12
        stack.alignment = .centerY
        addItem(nil, "Run Setup Assistant", caption: text.stringValue,
                keywords: ["setup", "assistant", "onboarding", "wizard", "first launch"], views: [stack], focus: button)
        return stack
    }

    /// A card: a bold title over a rounded box holding `views`; `widths` stretch to the box.
    private func card(_ chapter: SettingsChapter, _ views: [NSView], widths: [NSView]) -> NSView {
        let title = chapter.title
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.setAccessibilityRole(.staticText)
        let inner = NSStackView(views: views)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 12
        inner.translatesAutoresizingMaskIntoConstraints = false
        let box = CardView()
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
        ])
        for view in widths {
            let width = view.widthAnchor.constraint(equalTo: inner.widthAnchor)
            width.isActive = true
            if view is NSGridView { gridWidths[ObjectIdentifier(view)] = width }
        }
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel(title)
        let section = NSStackView(views: [heading, box])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        box.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        sections[chapter] = section
        return section
    }

    private func makeGrid() -> NSGridView {
        let grid = NSGridView()
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grids.append(grid)
        return grid
    }

    /// A setting made of a card's views (a checkbox and its note); `context`: views shown along with it;
    /// `titledBy`: a checkbox whose title changes at run time, searched as shown.
    private func addItem(_ chapter: SettingsChapter?, _ title: String, caption: String, keywords: [String],
                         views: [NSView], focus: NSView?, context: [NSView] = [], titledBy checkbox: NSButton? = nil) {
        var liveTitle: (@MainActor () -> String)?
        if let checkbox { liveTitle = { checkbox.title } }
        items.append(SearchItem(chapter: chapter, entry: SettingsSearch.Entry(title: title, caption: caption,
                                                                              keywords: keywords),
                                liveTitle: liveTitle, views: views, context: context, focus: focus))
    }

    /// A status row (`addRow`): its title and detail line as shown when searched.
    private func addRowItem(_ chapter: SettingsChapter, _ action: SetupAction, title: String? = nil,
                            keywords: [String]) {
        guard let row = rows[action] else { return }
        let titleLabel = row.title
        items.append(SearchItem(chapter: chapter, entry: SettingsSearch.Entry(
            title: title ?? row.title.stringValue, keywords: keywords), liveCaption: row.detail,
            liveTitle: { titleLabel.stringValue }, grid: row.grid, gridAnchor: row.icon, action: action,
            focus: row.button))
    }

    private func finishRow(in grid: NSGridView) {
        // The icons in a narrow column, so the titles line up at the card's left on every card.
        grid.column(at: 0).width = 24
        grid.column(at: 0).xPlacement = .center
        grid.column(at: 2).xPlacement = .trailing
        grid.row(at: grid.numberOfRows - 1).yPlacement = .center
    }

    /// A status row: icon, bold title over a detail line, and a button with an optional link under it (`set`).
    private func addRow(_ action: SetupAction, _ title: String, to grid: NSGridView) {
        let icon = NSImageView()
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let (text, titleLabel, detail) = Self.labels(title)
        let button = NSButton(title: "", target: self, action: #selector(buttonPressed(_:)))
        button.bezelStyle = .push
        button.tag = action.rawValue
        let link = NSButton(title: "", target: self, action: #selector(buttonPressed(_:)))
        link.isBordered = false
        link.isHidden = true
        let buttons = NSStackView(views: [button, link])
        buttons.orientation = .vertical
        buttons.alignment = .trailing
        buttons.spacing = 2
        grid.addRow(with: [icon, text, buttons])
        finishRow(in: grid)
        rows[action] = Row(icon: icon, title: titleLabel, detail: detail, button: button, link: link, grid: grid)
    }

    /// A row whose control is a pop-up menu, a segmented control, or a slider; searched by its title, detail, and
    /// `keywords`. `focus`: what Return in the search focuses, when not `control`.
    private func addControlRow(_ chapter: SettingsChapter, _ symbol: String, _ title: String, _ detailText: String,
                               keywords: [String], control: NSView, focus: NSView? = nil, to grid: NSGridView) {
        let (text, _, detail) = Self.labels(title)
        detail.stringValue = detailText
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        // 200 points; narrower in a narrow window, once the title column has given way (`labels`).
        let controlWidth = control.widthAnchor.constraint(equalToConstant: 200)
        controlWidth.priority = NSLayoutConstraint.Priority(270)
        controlWidth.isActive = true
        // A segmented control keeps room for its labels; a pop-up truncates its title.
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: control is NSSegmentedControl ? 160 : 140)
            .isActive = true
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        grid.addRow(with: [icon, text, control])
        finishRow(in: grid)
        items.append(SearchItem(chapter: chapter, entry: SettingsSearch.Entry(title: title, caption: detailText,
                                                                              keywords: keywords),
                                grid: grid, gridAnchor: icon, focus: focus ?? control))
    }

    /// A row's bold title over its detail line: `textWidth` wide, narrower in a narrow window (the detail wraps at
    /// the width it gets; the title truncates last).
    private static func labels(_ title: String) -> (NSStackView, title: NSTextField, detail: NSTextField) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(300), for: .horizontal)
        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleLabel, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth).isActive = true
        let preferred = text.widthAnchor.constraint(equalToConstant: textWidth)
        preferred.priority = NSLayoutConstraint.Priority(260)
        preferred.isActive = true
        // Below this the control gives way first (`addControlRow`), so the detail never wraps a word a line.
        let readable = text.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        readable.priority = NSLayoutConstraint.Priority(280)
        readable.isActive = true
        return (text, titleLabel, detail)
    }

    /// A note under a setting; it wraps at the width it gets (the card's).
    private static func note(_ text: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        return note
    }

    /// A checkbox whose title wraps when the card is narrower than it (the window beside a call's window).
    private static func wrapsTitle(_ checkbox: NSButton) {
        checkbox.lineBreakMode = .byWordWrapping
        checkbox.usesSingleLineMode = false
        checkbox.cell?.wraps = true
        checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    // MARK: - State

    func update(_ state: SetupState) {
        updating = true
        defer {
            updating = false
            if searchedTextChangedInUpdate {
                searchedTextChangedInUpdate = false
                refreshSearch()
            } else if matches != nil {
                placeBestMatchOutline()  // a title or line of another height can move the best match
            }
        }
        let language = DictationLanguage.name(of: state.locale)
        updateLanguagePopup(state)
        select(shortcutPopup, state.shortcut.rawValue)
        shortcutPopup.isEnabled = state.shortcutChangeable
        select(retentionPopup, state.historyRetention.rawValue)
        openAtLaunchToggle.state = state.openWindowAtLaunch ? .on : .off
        appearanceControl.selectedSegment = AppearanceChoice.allCases.firstIndex(of: state.appearance) ?? 0
        fillerToggle.isEnabled = state.fillerExamples != nil
        fillerToggle.state = state.removeFillers && state.fillerExamples != nil ? .on : .off
        setSearched(fillerToggle, title: state.fillerExamples.map { "Remove filler words (\($0))" }
            ?? "Remove filler words — none known for \(language)")
        previewToggle.state = state.showPreview ? .on : .off
        aiFixToggle.isEnabled = state.aiFixUnavailable == nil
        aiFixToggle.state = state.aiFix && state.aiFixUnavailable == nil ? .on : .off
        setSearched(aiFixToggle, title: state.aiFixUnavailable.map { "\(Self.aiFixTitle) — unavailable: \($0)" }
            ?? Self.aiFixTitle)
        spokenCodeToggle.state = state.spokenCode ? .on : .off
        spokenCodeBackticksToggle.state = state.spokenCodeBackticks ? .on : .off
        spokenCodeBackticksToggle.isEnabled = state.spokenCode
        opacitySlider.isEnabled = state.showPreview
        // Leave the slider alone while the user drags it.
        if NSEvent.pressedMouseButtons == 0 { opacitySlider.doubleValue = state.previewOpacity }
        opacityValue.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded())) %"

        switch state.microphone {
        case "authorized":
            set(.microphone, .done, "Granted", button: "Open Settings")
        case "notDetermined":
            set(.microphone, .pending, "Not requested yet — macOS asks once", button: "Request…")
        default:
            set(.microphone, .problem, "Denied — turn on Voice is Local in System Settings", button: "Open Settings")
        }
        setPermission(.accessibility, settings: .accessibilitySettings, granted: state.accessibility,
                      state.accessibility ? .done : .problem,
                      state.accessibility ? "Granted — used to insert text into the focused field"
                                          : "Not granted — click Allow…, then turn on Voice is Local")
        // Accessibility is what the hotkey tap needs; this row appears only after macOS refused the tap anyway.
        setRowHidden(.inputMonitoring, !state.inputMonitoringNeeded)
        setPermission(.inputMonitoring, settings: .inputMonitoringSettings, granted: state.inputMonitoring,
                      state.inputMonitoring ? .done : .problem,
                      state.inputMonitoring
                          ? "Granted — quit and reopen Voice is Local if the shortcut still does not work"
                          : "macOS refused the hold-to-talk shortcut with Accessibility on. Click Allow…, turn on "
                            + "Voice is Local under Input Monitoring, then quit and reopen Voice is Local.")
        recordSystemAudioToggle.state = state.recordSystemAudio ? .on : .off
        screenCaptureToggle.state = state.screenCaptureDefault ? .on : .off
        deepTranscriptionToggle.state = state.deepTranscriptionEnabled ? .on : .off
        // Off until the model is installed; turning it on is offered through the model's Download button.
        deepTranscriptionToggle.isEnabled = state.deepTranscriptionModel == "installed"
            || state.deepTranscriptionEnabled
        meetingSummariesToggle.isEnabled = state.meetingSummariesUnavailable == nil
        meetingSummariesToggle.state = state.meetingSummaries && state.meetingSummariesUnavailable == nil ? .on : .off
        setSearched(meetingSummariesToggle, title: state.meetingSummariesUnavailable.map {
            "\(Self.meetingSummariesTitle) — unavailable: \($0)"
        } ?? Self.meetingSummariesTitle)
        // Never marked as a problem: without it meetings record the microphone alone.
        if state.systemAudio {
            set(.systemAudio, .done, state.recordSystemAudio
                ? (state.screenCaptureDefault ? "Granted — meetings record the computer's audio and capture the screen"
                    : "Granted — meetings record the computer's audio")
                : state.screenCaptureDefault ? "Granted — meetings capture the screen"
                    : "Granted — recording the computer's audio is off under Meetings", button: nil)
        } else if state.recordSystemAudio || state.screenCaptureDefault {
            setPermission(.systemAudio, settings: .systemAudioSettings, granted: false, .pending,
                          "Meetings record the computer's audio (the other side of a call, a video) and can capture "
                          + "the screen. Click Allow…, turn on Voice is Local under Screen & System Audio Recording, "
                          + "then quit and reopen Voice is Local. Until then meetings record the microphone only, "
                          + "without the screen.")
        } else {
            setPermission(.systemAudio, settings: .systemAudioSettings, granted: false, .pending,
                          "Not needed — recording the computer's audio is off under Meetings")
        }

        if let title = rows[.assets]?.title { setSearched(title, "Speech model: \(language)") }
        let canInstall = !state.installingAssets && !state.busy && !state.dictationEnabled && !state.enabling
        if state.installingAssets || state.assets == "downloading" {
            set(.assets, .pending, "Downloading and installing…", button: "Install", enabled: false)
        } else {
            switch state.assets {
            case nil: set(.assets, .pending, "Checking…", button: "Install", enabled: false)
            case "installed": set(.assets, .done, "Installed", button: nil)
            case "supported": set(.assets, .pending, "Not installed — downloads Apple's model for \(language)",
                                  button: "Install", enabled: canInstall)
            case "unsupported": set(.assets, .problem, "\(language) speech recognition is not supported on this Mac", button: nil)
            case let other?: set(.assets, .problem, "Status unknown (\(other))", button: "Install", enabled: canInstall)
            }
        }

        if state.enabling {
            set(.dictation, .pending, "Starting…", button: "Turn On", enabled: false)
        } else if state.dictationEnabled {
            set(.dictation, .done, "On — hold \(state.shortcutTitle), wait for Listening, speak, release",
                button: "Turn Off", enabled: !state.busy)
        } else {
            set(.dictation, .pending, "Off — turn it on once the permissions and speech model are ready",
                button: "Turn On", enabled: !state.installingAssets)
        }

        let install = "Install (21 MB download)"
        switch state.speakerModels {
        case "installing":
            set(.speakerModels, .pending, state.speakerModelsDetail ?? "Downloading…", button: install, enabled: false)
        case "verified":
            set(.speakerModels, .done, "Installed — meetings get speaker labels after they are saved", button: nil)
        case "notInstalled":
            set(.speakerModels, state.speakerModelsDetail == nil ? .pending : .problem,
                state.speakerModelsDetail.map { "Install failed: \($0)" }
                    ?? "Not installed — meetings are saved without speaker labels", button: install)
        case "damaged":
            set(.speakerModels, .problem, state.speakerModelsDetail.map { "Install failed: \($0)" }
                ?? "Damaged — install them again", button: install)
        case "unavailable":
            set(.speakerModels, .problem, "The voiceislocal tool is missing from VoiceIsLocal.app; rebuild Voice is Local with scripts/build-app.sh",
                button: nil)
        case "unknown":
            set(.speakerModels, .problem, "Could not check the speaker models; `voiceislocal doctor` shows why", button: install)
        case let other?:
            set(.speakerModels, .problem, "Status unknown (\(other))", button: install)
        case nil:
            set(.speakerModels, .pending, "Checking…", button: install, enabled: false)
        }

        let download = "Download (1.6 GB)"
        switch state.deepTranscriptionModel {
        case "installing":
            set(.deepTranscriptionModel, .pending, state.deepTranscriptionDetail ?? "Downloading…", button: download,
                enabled: false)
        case "installed":
            set(.deepTranscriptionModel, .done, state.deepTranscriptionEnabled
                ? "On — meetings get a final transcript from Whisper after they are saved"
                : "Model installed — turn on Deep transcription above", button: nil)
        case "downloading":
            set(.deepTranscriptionModel, .pending, "Downloading in another process…", button: download, enabled: false)
        case "notInstalled":
            set(.deepTranscriptionModel, state.deepTranscriptionDetail == nil ? .pending : .problem,
                state.deepTranscriptionDetail.map { "Download failed: \($0)" }
                    ?? "Model not installed — Whisper large-v3 turbo, about 1.6 GB, runs on this Mac", button: download)
        case "unknown":
            set(.deepTranscriptionModel, .problem, "Could not check the model; `voiceislocal doctor` shows why",
                button: download)
        case "unavailable":
            set(.deepTranscriptionModel, .problem,
                "The voiceislocal tool is missing from VoiceIsLocal.app; rebuild Voice is Local with scripts/build-app.sh",
                button: nil)
        case let other?:
            set(.deepTranscriptionModel, .problem, "Status unknown (\(other))", button: download)
        case nil:
            set(.deepTranscriptionModel, .pending, "Checking…", button: download, enabled: false)
        }

        for (action, pack) in [(SetupAction.naturalVoicesEnglish, NaturalVoicePack.english),
                               (.naturalVoicesFrench, .french)] {
            let row = (state.naturalVoices[pack] ?? NaturalVoiceDownload(pack: pack)).row
            set(action, row.done ? .done : row.problem ? .problem : .pending, row.detail, button: row.button,
                enabled: row.enabled)
        }
        // Voices installed since the menus were filled (a download that just ended) are offered.
        let installed = Set(state.naturalVoices.filter { $0.value.phase == .installed }.keys)
        if installed != shownNaturalVoices {
            shownNaturalVoices = installed
            refreshReadingCard()
        }

        let count = state.historyCount
        let kept = state.historyUnreadable ? "History could not be read; it may still keep dictations on this Mac"
            : count == 0 ? "No dictations kept"
            : "\(count) \(count == 1 ? "dictation" : "dictations") kept on this Mac"
        let recording = state.historyRetention.records ? "" : " — History is off; new dictations are not kept"
        set(.clearHistory, state.historyUnreadable ? .problem : count == 0 ? .pending : .done, kept + recording,
            button: "Clear History…", enabled: count > 0 || state.historyUnreadable)
        rows[.clearHistory]?.icon.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)
        rows[.clearHistory]?.icon.contentTintColor = .secondaryLabelColor
        historyAudioToggle.state = state.historyKeepsAudio ? .on : .off
        historyAudioUsage.stringValue = HistoryAudio.usageText(bytes: state.historyAudioBytes,
                                                               keeps: state.historyKeepsAudio
                                                                   && state.historyRetention.records)
    }

    /// A searched caption or title changed under an open search (a permission granted in System Settings, another
    /// reading folder, another dictation language; `setSearched`): runs the search again. The page stays where the user has it unless the best match
    /// changed.
    private func refreshSearch() {
        guard let previous = matches else { return }
        let current = rankedMatches() ?? []
        guard current != previous else {
            placeBestMatchOutline()  // a detail of another height can move the best match
            return
        }
        let offset = scroll.contentView.bounds.minY
        matches = current
        applyVisibility()
        view.layoutSubtreeIfNeeded()
        let bottom = max(0, document.frame.height - scroll.contentView.bounds.height)
        scrollTo(SettingsSearch.bestMatchChanged(from: previous, to: current) ? 0 : min(offset, bottom),
                 animated: false)
        trackChapter()
    }

    private func select(_ popup: NSPopUpButton, _ value: String) {
        guard popup.selectedItem?.representedObject as? String != value else { return }
        popup.selectItem(at: popup.indexOfItem(withRepresentedObject: value))
    }

    /// Rebuilt only when the list changes, so a refresh never replaces the menu while the user has it open.
    private func updateLanguagePopup(_ state: SetupState) {
        var groups = state.localeGroups
        if !groups.joined().contains(state.locale) { groups.insert([state.locale], at: 0) }
        if groups != shownLocaleGroups {
            shownLocaleGroups = groups
            languagePopup.removeAllItems()
            for (index, group) in groups.enumerated() {
                if index > 0 { languagePopup.menu?.addItem(.separator()) }
                for locale in group {
                    let item = NSMenuItem(title: DictationLanguage.name(of: locale), action: nil, keyEquivalent: "")
                    item.representedObject = locale
                    languagePopup.menu?.addItem(item)
                }
            }
        }
        select(languagePopup, state.locale)
        languagePopup.isEnabled = state.localeChangeable
    }

    /// Hides a status row for its state (Input Monitoring); the search never shows a row hidden so.
    private func setRowHidden(_ action: SetupAction, _ hidden: Bool) {
        guard stateHidden.contains(action) != hidden else { return }
        if hidden { stateHidden.insert(action) } else { stateHidden.remove(action) }
        guard matches != nil else {
            applyVisibility()
            return
        }
        matches = rankedMatches()
        applyVisibility()
        view.layoutSubtreeIfNeeded()
        trackChapter()
    }

    /// Shows a status row's button and link as `set` last asked, unless the row is hidden.
    private func applyRowButtons(_ action: SetupAction) {
        guard let row = rows[action] else { return }
        // A view shown inside a hidden grid row is left unplaced and draws over another row.
        let rowHidden = row.grid.cell(for: row.icon)?.row?.isHidden ?? false
        let button = row.wantsButton && !rowHidden
        if row.button.isHidden == button { row.button.isHidden = !button }
        let link = row.wantsLink && !rowHidden
        if row.link.isHidden == link { row.link.isHidden = !link }
    }

    /// A permission row (`PermissionButtons`): not granted, Allow… sends `action` (ask macOS) and the System
    /// Settings… link sends `settings` (open the page); granted, Open Settings sends `settings`.
    private func setPermission(_ action: SetupAction, settings: SetupAction, granted: Bool, _ mark: Mark,
                               _ detail: String) {
        let buttons = PermissionButtons.forPermission(granted: granted)
        func send(_ button: PermissionButtons.Button) -> SetupAction { button.step == .ask ? action : settings }
        set(action, mark, detail, button: buttons.primary.title, sends: send(buttons.primary),
            link: buttons.secondary.map { ($0.title, send($0)) })
    }

    /// `sends`: the action the button reports (the row's own by default); `link`: the link under it, if any.
    private func set(_ action: SetupAction, _ mark: Mark, _ detail: String, button title: String?, enabled: Bool = true,
                     sends: SetupAction? = nil, link: (title: String, sends: SetupAction)? = nil) {
        guard let row = rows[action] else { return }
        let (symbol, color): (String, NSColor) = switch mark {
        case .done: ("checkmark.circle.fill", .systemGreen)
        case .pending: ("circle.dashed", .secondaryLabelColor)
        case .problem: ("exclamationmark.circle.fill", .systemOrange)
        }
        let description: String = switch mark {
        case .done: "Done"
        case .pending: "Not done yet"
        case .problem: "Needs attention"
        }
        row.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        row.icon.contentTintColor = color
        setSearched(row.detail, detail)
        rows[action]?.wantsButton = title != nil
        rows[action]?.wantsLink = link != nil
        applyRowButtons(action)
        row.button.title = title ?? ""
        row.button.tag = (sends ?? action).rawValue
        row.button.isEnabled = enabled
        row.button.setAccessibilityLabel(title.map { "\($0) — \(row.title.stringValue)" })
        if let link {
            if row.link.title != link.title {
                row.link.attributedTitle = NSAttributedString(string: link.title, attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.linkColor,
                ])
            }
            row.link.tag = link.sends.rawValue
            row.link.setAccessibilityLabel("\(link.title) — \(row.title.stringValue)")
        }
    }

    // MARK: - Chapters

    var searchField: NSSearchField? { search }

    /// The view that holds `chapter`'s card in the page (tests).
    func section(for chapter: SettingsChapter) -> NSView? { sections[chapter] }

    /// The page is scrolled to its top.
    var isAtTop: Bool { scroll.contentView.bounds.minY <= 1 }

    /// Scrolls to `chapter`'s card, or to the top for nil, smoothly when `animated` (never with Reduce Motion).
    /// A search is cleared first, so the chapter shows whole. The sidebar already marks it: `onChapterChange` is not
    /// called.
    func show(chapter: SettingsChapter?, animated: Bool) {
        if matches != nil || !search.stringValue.isEmpty {
            search.stringValue = ""
            matches = nil
            applyVisibility()
        }
        view.layoutSubtreeIfNeeded()
        currentChapter = chapter ?? .general
        chosenChapter = chapter
        let clip = scroll.contentView
        let target = chapter.flatMap { sections[$0] }.map {
            SettingsChapterTracking.offset(toShow: Double(top(of: $0)), viewport: Double(clip.bounds.height),
                                           contentHeight: Double(document.frame.height), margin: 12)
        } ?? 0
        scrollTo(CGFloat(target), animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func scrollTo(_ y: CGFloat, animated: Bool) {
        let clip = scroll.contentView
        let point = NSPoint(x: clip.bounds.minX, y: y)
        let animating = scrollGeneration.isScrolling
        let token = scrollGeneration.begin()
        guard animated, abs(clip.bounds.minY - y) > 1 else {
            if animating {
                // Replaces the scroll still animating, which would otherwise carry on to its own target.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    clip.animator().setBoundsOrigin(point)
                }
            } else {
                clip.scroll(to: point)
            }
            scroll.reflectScrolledClipView(clip)
            scrollGeneration.end(token)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(point)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scroll.reflectScrolledClipView(self.scroll.contentView)
                // An older scroll finishing while a newer one runs leaves tracking off (`SettingsScrollGeneration`).
                self.scrollGeneration.end(token)
            }
        })
    }

    /// A view's top in the page.
    private func top(of view: NSView) -> CGFloat {
        view.convert(view.bounds, to: document).minY
    }

    @objc private func scrolled() {
        guard !scrollGeneration.isScrolling else { return }
        trackChapter()
    }

    /// Marks the chapter at the top in the sidebar when it changed (`SettingsChapterTracking`).
    private func trackChapter() {
        let tops: [Double?] = SettingsChapter.allCases.map { chapter in
            guard let section = sections[chapter], !section.isHidden else { return nil }
            return Double(top(of: section))
        }
        let clip = scroll.contentView.bounds
        // The user's choice ends once its card leaves the view; only a choice, never the chapter scrolling met last,
        // holds at the end of the page.
        if let chosen = chosenChapter, !SettingsChapterTracking.keepsChosen(
            top: tops[chosen.rawValue], offset: Double(clip.minY), viewport: Double(clip.height)) {
            chosenChapter = nil
        }
        let index = SettingsChapterTracking.chapter(
            offset: Double(clip.minY), viewport: Double(clip.height), contentHeight: Double(document.frame.height),
            tops: tops, chosen: chosenChapter?.rawValue)
        guard let index, let chapter = SettingsChapter(rawValue: index) else {
            if matches != nil { onChapterChange?(nil) }  // nothing matches: still the Settings row
            return
        }
        currentChapter = chapter
        // While a search is open the sidebar marks the Settings row: the filtered page's cards are not chapters in
        // order. Otherwise the chapter at the top, reported even when unchanged here: the sidebar may show the
        // Settings row (the page opened at its top, or the row was clicked) while this is General, and it ignores a
        // chapter it already marks.
        onChapterChange?(SettingsChapterTracking.markWhileScrolling(searching: matches != nil, chapter: index)
            .flatMap(SettingsChapter.init(rawValue:)))
    }

    /// What the sidebar marks when Settings comes on screen as it was left (⌘, or Settings…): nil for the Settings row.
    var sidebarMarkOnShow: SettingsChapter? {
        SettingsChapterTracking.markOnShow(searching: matches != nil, atTop: isAtTop, current: currentChapter.rawValue)
            .flatMap(SettingsChapter.init(rawValue:))
    }

    // MARK: - Search

    /// Where the page was when a search began; clearing the search goes back there.
    private var offsetBeforeSearch: CGFloat = 0

    @objc private func searchChanged() {
        let wasSearching = matches != nil
        if !wasSearching { offsetBeforeSearch = scroll.contentView.bounds.minY }
        matches = rankedMatches()
        applyVisibility()
        view.layoutSubtreeIfNeeded()
        if matches != nil {
            scrollTo(0, animated: false)
        } else if wasSearching {
            scrollTo(min(offsetBeforeSearch, max(0, document.frame.height - scroll.contentView.bounds.height)),
                     animated: false)
        }
        trackChapter()
        announce(matches.map { matches in
            guard let best = matches.first else { return "No settings match" }
            let count = "\(matches.count) \(matches.count == 1 ? "setting matches" : "settings match")"
            return "\(count); Return goes to \(title(of: items[best]))"
        })
    }

    /// The best match, what Return goes to, is outlined while the search lasts; without a search, nothing is.
    private func placeBestMatchOutline() {
        guard let best = matches?.first else {
            outline?.removeFromSuperview()
            outline = nil
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let frame = frame(of: items[best]) else { return }
        if let outline {
            outline.place(over: frame)
        } else {
            let made = SettingsHighlightView(frame: .zero)
            made.place(over: frame)
            document.addSubview(made)
            outline = made
        }
    }

    private func title(of item: SearchItem) -> String {
        let title = item.liveTitle?() ?? item.entry.title
        return title.isEmpty ? item.chapter?.title ?? "Settings" : title
    }

    /// The items matching the query, best first (`SettingsSearch`), without rows their state hides; nil without a
    /// query.
    private func rankedMatches() -> [Int]? {
        let query = search.stringValue
        guard !SettingsSearch.words(query).isEmpty else { return nil }
        let candidates = items.indices.filter { items[$0].action.map { !stateHidden.contains($0) } ?? true }
        let entries = candidates.map { index in
            var entry = items[index].entry
            if let live = items[index].liveCaption { entry.caption = live.stringValue }
            if let live = items[index].liveTitle { entry.title = live() }
            return entry
        }
        return SettingsSearch.rank(query, entries).map { candidates[$0] }
    }

    /// Shows the items that match (all without a query), the cards holding them with their headings, and a line
    /// when nothing matches.
    private func applyVisibility() {
        let shown = matches.map(Set.init)
        var visibleViews = Set<ObjectIdentifier>()
        var chapters = Set<SettingsChapter>()
        for (index, item) in items.enumerated() where shown?.contains(index) ?? true {
            for view in item.views + item.context { visibleViews.insert(ObjectIdentifier(view)) }
            if let chapter = item.chapter { chapters.insert(chapter) }
        }
        for (index, item) in items.enumerated() {
            for view in item.views + item.context {
                let visible = visibleViews.contains(ObjectIdentifier(view))
                if view.isHidden == visible { view.isHidden = !visible }
            }
            guard let grid = item.grid, let anchor = item.gridAnchor, let row = grid.cell(for: anchor)?.row else {
                continue
            }
            let hidden = !(shown?.contains(index) ?? true) || item.action.map(stateHidden.contains) == true
            if row.isHidden != hidden { row.isHidden = hidden }
            // Never leave a view of a hidden row on screen, unplaced.
            for column in 0..<row.numberOfCells {
                if let view = row.cell(at: column).contentView, view.isHidden != hidden { view.isHidden = hidden }
            }
        }
        for grid in grids {
            let empty = (0..<grid.numberOfRows).allSatisfy { grid.row(at: $0).isHidden }
            if grid.isHidden != empty { grid.isHidden = empty }
            if let width = gridWidths[ObjectIdentifier(grid)], width.isActive == empty { width.isActive = !empty }
        }
        for (chapter, section) in sections {
            let hidden = shown != nil && !chapters.contains(chapter)
            if section.isHidden != hidden { section.isHidden = hidden }
        }
        for action in rows.keys { applyRowButtons(action) }
        let none = matches?.isEmpty == true
        noMatches.stringValue = none ? "No settings match “\(search.stringValue)”. Press Escape to see them all." : ""
        if noMatches.isHidden == none { noMatches.isHidden = !none }
        placeBestMatchOutline()
    }

    /// Return in the search field: clears the search, scrolls the best match into view, and outlines it for a
    /// moment; its control takes the focus when it can.
    private func goToBestMatch() {
        guard let best = matches?.first else {
            NSSound.beep()
            return
        }
        let item = items[best]
        search.stringValue = ""
        matches = nil
        applyVisibility()
        view.layoutSubtreeIfNeeded()
        guard let frame = frame(of: item) else { return }
        let clip = scroll.contentView.bounds
        // Below the top, so the card's heading and the rows above it give context.
        let target = max(0, min(frame.minY - 80, document.frame.height - clip.height))
        scrollTo(target, animated: false)
        chosenChapter = item.chapter
        if let chapter = item.chapter {
            currentChapter = chapter
            onChapterChange?(chapter)
        } else {
            // Run Setup Assistant, below the cards: the sidebar marks the chapter at its place, as scrolling there
            // would (the last one at the end of the page).
            trackChapter()
        }
        highlight = SettingsHighlightView.flash(frame, in: document, replacing: highlight)
        if let focus = item.focus, focus.canBecomeKeyView { view.window?.makeFirstResponder(focus) }
        announce("Went to \(title(of: item))")
    }

    /// The item's frame in the page: its grid row, or its views.
    private func frame(of item: SearchItem) -> NSRect? {
        var views = item.views.filter { !$0.isHidden }
        if let grid = item.grid, let anchor = item.gridAnchor, let row = grid.cell(for: anchor)?.row {
            views += (0..<row.numberOfCells).compactMap { row.cell(at: $0).contentView }
        }
        let frames = views.map { $0.convert($0.bounds, to: document) }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    private func announce(_ text: String?) {
        guard let text, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: search, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    // MARK: - Actions

    @objc private func opacityChanged(_ sender: NSSlider) {
        opacityValue.stringValue = "\(Int((sender.doubleValue * 100).rounded())) %"
        callbacks.opacity(sender.doubleValue)
    }

    @objc private func languageChosen(_ sender: NSPopUpButton) {
        guard let locale = sender.selectedItem?.representedObject as? String else { return }
        callbacks.language(locale)
    }

    @objc private func appearanceChosen(_ sender: NSSegmentedControl) {
        guard AppearanceChoice.allCases.indices.contains(sender.selectedSegment) else { return }
        callbacks.appearance(AppearanceChoice.allCases[sender.selectedSegment])
    }

    @objc private func shortcutChosen(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let choice = HotkeyChoice(rawValue: raw) else {
            return
        }
        callbacks.shortcut(choice)
    }

    @objc private func retentionChosen(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let retention = HistoryRetention(rawValue: raw) else { return }
        callbacks.retention(retention)
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let action = SetupAction(rawValue: sender.tag) else { return }
        callbacks.perform(action)
    }

    // MARK: - NSSearchFieldDelegate

    /// Return goes to the best match; Escape clears the search (and does nothing more when it is empty).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            goToBestMatch()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            guard !search.stringValue.isEmpty else { return false }
            search.stringValue = ""
            searchChanged()
            return true
        default:
            return false
        }
    }
}

/// A rounded box in the control background colour, with a hairline border; follows light and dark mode.
@MainActor
final class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
