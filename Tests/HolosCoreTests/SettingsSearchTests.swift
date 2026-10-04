import Testing
@testable import HolosCore

private typealias Entry = SettingsSearch.Entry

/// A few of Settings' rows, in page order.
private let page: [Entry] = [
    Entry(title: "Open the Voice is Local window when it starts", caption: "Closing the window keeps Voice is Local "
          + "running in the menu bar", keywords: ["launch", "startup", "login"]),
    Entry(title: "Appearance", caption: "Every Voice is Local window and the dictation preview; System follows macOS",
          keywords: ["dark mode", "light mode", "theme"]),
    Entry(title: "Microphone", caption: "Granted", keywords: ["mic", "privacy"]),
    Entry(title: "Hold-to-talk shortcut", caption: "Hold it, wait for Listening, speak, release",
          keywords: ["hotkey", "right option"]),
    Entry(title: "Dictation language", caption: "Used from the next dictation", keywords: ["locale"]),
    Entry(title: "Record the computer's audio (system sound) in meetings",
          caption: "On: meetings record your microphone and everything the Mac plays", keywords: ["calls"]),
    Entry(title: "Speed", caption: "0.8× to 1.4× of the voice's normal pace", keywords: ["rate", "reading speed"]),
]

private func titles(_ query: String) -> [String] {
    SettingsSearch.rank(query, page).map { page[$0].title }
}

@Test func aWordMatchesAtTheStartAWordStartInsideOrAsLettersInOrder() {
    #expect(SettingsSearch.match("mic", in: "Microphone", subsequence: true) == .start)
    #expect(SettingsSearch.match("talk", in: "Hold-to-talk shortcut", subsequence: true) == .wordStart)
    #expect(SettingsSearch.match("phone", in: "Microphone", subsequence: true) == .inside)
    #expect(SettingsSearch.match("dctn", in: "Dictation language", subsequence: true) == .subsequence)
    #expect(SettingsSearch.match("dctn", in: "Dictation language", subsequence: false) == nil)
    #expect(SettingsSearch.match("xyz", in: "Dictation language", subsequence: true) == nil)
    let order: [SettingsSearch.Match] = [.subsequence, .inside, .wordStart, .start]
    #expect(order == order.sorted())
}

@Test func shortWordsOnlyMatchTheStartOfAWord() {
    #expect(SettingsSearch.match("ph", in: "Microphone", subsequence: true) == nil)
    #expect(SettingsSearch.match("mi", in: "Microphone", subsequence: true) == .start)
    #expect(SettingsSearch.match("ct", in: "Dictation", subsequence: true) == nil)
}

@Test func lettersInOrderStayWithinOneWord() {
    // "s" from "speech", "m" from "model": not one word.
    #expect(SettingsSearch.match("smd", in: "speech model", subsequence: true) == nil)
    #expect(SettingsSearch.isSubsequence("spd", of: "speed"))
    #expect(!SettingsSearch.isSubsequence("sdp", of: "speed"))
}

@Test func caseDiacriticsAndWidthAreIgnored() {
    #expect(SettingsSearch.match("THEME", in: "Thème", subsequence: true) == .start)
    #expect(SettingsSearch.match("francais", in: "Français (Canada)", subsequence: true) == .start)
    #expect(SettingsSearch.match("ｍｉｃ", in: "Microphone", subsequence: true) == .start)
    #expect(SettingsSearch.words("Hold-to-talk, Écran") == ["hold", "to", "talk", "ecran"])
}

@Test func theRowNamedByTheQueryRanksFirst() {
    #expect(titles("mic").first == "Microphone")
    #expect(titles("Mic").contains("Record the computer's audio (system sound) in meetings"))
    #expect(titles("dark") == ["Appearance"])
    #expect(titles("hotkey") == ["Hold-to-talk shortcut"])
    #expect(titles("speed").first == "Speed")
}

@Test func everyWordOfTheQueryMustMatch() {
    #expect(titles("dictation language") == ["Dictation language"])
    #expect(titles("dictation zebra").isEmpty)
    #expect(titles("record meetings") == ["Record the computer's audio (system sound) in meetings"])
}

@Test func aTitleCountsMoreThanAKeywordAndAKeywordMoreThanACaption() {
    let title = Entry(title: "Launch window")
    let keyword = Entry(title: "Other", keywords: ["launch"])
    let caption = Entry(title: "Other", caption: "launch")
    #expect(SettingsSearch.rank("launch", [caption, keyword, title]) == [2, 1, 0])
}

@Test func theWholePhraseInTheTitleRanksHigher() {
    let phrase = Entry(title: "Speech model")
    let scattered = Entry(title: "Model of speech")
    #expect(SettingsSearch.rank("speech model", [scattered, phrase]) == [1, 0])
}

@Test func equalScoresKeepThePageOrder() {
    let entries = [Entry(title: "Keep audio"), Entry(title: "Keep dictations"), Entry(title: "Keep audio")]
    #expect(SettingsSearch.rank("keep", entries) == [0, 1, 2])
}

@Test func aRefreshMovesThePageOnlyWhenTheBestMatchChanged() {
    // A live caption changed under an open search: the same best match keeps the page where the user has it.
    #expect(!SettingsSearch.bestMatchChanged(from: [3, 5], to: [3]))
    #expect(!SettingsSearch.bestMatchChanged(from: [3], to: [3, 1, 2]))
    #expect(SettingsSearch.bestMatchChanged(from: [3, 5], to: [5]))
    #expect(SettingsSearch.bestMatchChanged(from: [3], to: []))
    #expect(SettingsSearch.bestMatchChanged(from: [], to: [2]))
    #expect(!SettingsSearch.bestMatchChanged(from: [], to: []))
}

@Test func aTitleAsShownNowIsSearched() {
    // The speech model's row shows its language in the title; the caption only says Installed.
    let shown = Entry(title: "Speech model: French (Canada)", caption: "Installed")
    #expect(SettingsSearch.rank("French speech", [shown]) == [0])
    #expect(SettingsSearch.rank("speech model french", [shown]) == [0])
    #expect(SettingsSearch.rank("French speech", [Entry(title: "Speech model", caption: "Installed")]).isEmpty)
}

@Test func onlyTheLatestScrollEndsTheSuppression() {
    var generation = SettingsScrollGeneration()
    #expect(!generation.isScrolling)
    let meetings = generation.begin()
    #expect(generation.isScrolling)
    // Reading chosen before the Meetings scroll finished.
    let reading = generation.begin()
    // The Meetings animation completes: Reading's is still running.
    generation.end(meetings)
    #expect(generation.isScrolling)
    generation.end(reading)
    #expect(!generation.isScrolling)
    // A late completion of an old scroll changes nothing.
    let next = generation.begin()
    generation.end(reading)
    #expect(generation.isScrolling)
    generation.end(next)
    #expect(!generation.isScrolling)
}

@Test func anEmptyQueryMatchesNothing() {
    #expect(SettingsSearch.rank("", page).isEmpty)
    #expect(SettingsSearch.rank("  – ", page).isEmpty)
    #expect(SettingsSearch.score("", Entry(title: "Anything")) == nil)
}

// MARK: - Chapters

/// Six chapters on a 2 000-point page seen through 700 points.
private let tops: [Double?] = [20, 300, 700, 1_300, 1_650, 1_820]

private func chapter(_ offset: Double, tops: [Double?] = tops, chosen: Int? = nil) -> Int? {
    SettingsChapterTracking.chapter(offset: offset, viewport: 700, contentHeight: 2_000, tops: tops,
                                    chosen: chosen)
}

@Test func theChapterWhoseTopReachedTheVisibleTopIsMarked() {
    #expect(chapter(0) == 0)
    #expect(chapter(200) == 0)
    // Within the margin below the top counts as reached.
    #expect(chapter(250) == 1)
    #expect(chapter(300) == 1)
    #expect(chapter(699) == 2)
    #expect(chapter(1_250) == 3)
}

@Test func atTheEndTheChosenChapterInViewStaysMarked() {
    // The page ends at 1 300: the last two chapters can never reach the top.
    #expect(chapter(1_300) == 5)
    #expect(chapter(1_300, chosen: 4) == 4)
    #expect(chapter(1_300, chosen: 5) == 5)
    // Chosen, but scrolled past (its top is above the view).
    #expect(chapter(1_300, chosen: 2) == 5)
}

@Test func settingsReopensMarkingTheChapterItShowsOrSettingsItself() {
    // Left on Meetings: ⌘, marks Meetings.
    #expect(SettingsChapterTracking.markOnShow(searching: false, atTop: false, current: 3) == 3)
    // At the top of the page: the Settings row.
    #expect(SettingsChapterTracking.markOnShow(searching: false, atTop: true, current: 0) == nil)
    // A search is open: its top is not the page's, and the cards shown are not chapters in order: the Settings row,
    // wherever the filtered page is scrolled.
    #expect(SettingsChapterTracking.markOnShow(searching: true, atTop: true, current: 1) == nil)
    #expect(SettingsChapterTracking.markOnShow(searching: true, atTop: false, current: 4) == nil)
}

@Test func whileSearchingScrollingMarksTheSettingsRow() {
    #expect(SettingsChapterTracking.markWhileScrolling(searching: true, chapter: 2) == nil)
    #expect(SettingsChapterTracking.markWhileScrolling(searching: false, chapter: 2) == 2)
    #expect(SettingsChapterTracking.markWhileScrolling(searching: false, chapter: 0) == 0)
}

@Test func goingToTheFooterMarksTheChapterAtItsPlace() {
    // Return on Run Setup Assistant (no chapter of its own) scrolls to the end with nothing chosen: the last chapter.
    #expect(chapter(1_300, chosen: nil) == 5)
    // Short of the end (the page could not reach it), the chapter at the top.
    #expect(SettingsChapterTracking.chapter(offset: 1_000, viewport: 700, contentHeight: 2_000, tops: tops,
                                            chosen: nil) == 2)
}

@Test func aChosenChapterHoldsWhileItsCardsTopIsInView() {
    // Chosen Reading (top 1 650) at the end of the page (offset 1 300, 700 high): in view.
    #expect(SettingsChapterTracking.keepsChosen(top: 1_650, offset: 1_300, viewport: 700))
    // Scrolled back up until its top left the bottom of the view.
    #expect(!SettingsChapterTracking.keepsChosen(top: 1_650, offset: 900, viewport: 700))
    // Scrolled on past it: its top went above the view.
    #expect(!SettingsChapterTracking.keepsChosen(top: 700, offset: 800, viewport: 700))
    // Hidden by a search.
    #expect(!SettingsChapterTracking.keepsChosen(top: nil, offset: 0, viewport: 700))
}

/// Scrolling by hand down to the end, as the pane tracks it: nothing was chosen, so the end marks the last chapter
/// even though Meetings and Reading, met on the way down, are still in view.
@Test func scrollingByHandToTheEndMarksTheLastChapter() {
    var chosen: Int?
    var marked: Int?
    for offset in stride(from: 0.0, through: 1_300, by: 50) {
        if let index = chosen, !SettingsChapterTracking.keepsChosen(top: tops[index], offset: offset, viewport: 700) {
            chosen = nil
        }
        marked = chapter(offset, chosen: chosen)
    }
    #expect(marked == 5)
    // Chose Reading from the sidebar (the page went to the end), then scrolled up a little and back down: Reading
    // stays marked while its card is in view.
    chosen = 4
    for offset in [1_300.0, 1_200, 1_300] {
        if let index = chosen, !SettingsChapterTracking.keepsChosen(top: tops[index], offset: offset, viewport: 700) {
            chosen = nil
        }
        marked = chapter(offset, chosen: chosen)
    }
    #expect(marked == 4)
    // Up until Reading's top leaves the view: the choice ends, and the end marks the last chapter again.
    for offset in [900.0, 1_300] {
        if let index = chosen, !SettingsChapterTracking.keepsChosen(top: tops[index], offset: offset, viewport: 700) {
            chosen = nil
        }
        marked = chapter(offset, chosen: chosen)
    }
    #expect(chosen == nil)
    #expect(marked == 5)
}

@Test func hiddenChaptersAreSkipped() {
    let searched: [Double?] = [nil, 20, nil, 400, nil, nil]
    #expect(chapter(0, tops: searched) == 1)
    #expect(chapter(380, tops: searched) == 3)
    #expect(chapter(0, tops: [nil, nil]) == nil)
    // A page shorter than the view is never "at the end": the first chapter shown stays marked.
    #expect(SettingsChapterTracking.chapter(offset: 0, viewport: 700, contentHeight: 500, tops: searched,
                                            chosen: 3) == 1)
}

@Test func choosingAChapterScrollsItToTheTopAsFarAsThePageGoes() {
    #expect(SettingsChapterTracking.offset(toShow: 700, viewport: 700, contentHeight: 2_000, margin: 12) == 688)
    #expect(SettingsChapterTracking.offset(toShow: 1_820, viewport: 700, contentHeight: 2_000, margin: 12) == 1_300)
    #expect(SettingsChapterTracking.offset(toShow: 0, viewport: 700, contentHeight: 2_000, margin: 12) == 0)
    #expect(SettingsChapterTracking.offset(toShow: 20, viewport: 700, contentHeight: 500, margin: 12) == 0)
}
