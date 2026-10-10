# Review window

The transcript Review window. §5.10 comes from the build plan and names the PR that built it and the rounds
that changed it; the code cites it for behaviour.

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](../meeting-design.md) lists the file each is in.

### 5.10 PR9: Transcript review window (wave 5)

**Goal.** Name the speakers of a 3 h meeting in about 10 minutes: see speakers and
turns, play audio, reassign, merge, split, confirm suggestions in bulk, find more
speakers, undo, export.

**Files.**

- Add `Sources/HolosMeeting/Review/ReviewSession.swift` (`@MainActor`, no AppKit),
  `Sources/HolosMeeting/Review/SessionAudioComposition.swift`.
- Add `Sources/HolosApp/Review/`: `ReviewWindow.swift`, `SpeakerSidebarView.swift`,
  `TurnListView.swift`, `ReviewPlayer.swift`, `ReviewPanes.swift` (the speakers pane that
  hides); `Sources/HolosSpeakers/ShortInterjections.swift`.
- Change `Sources/HolosApp/MeetingsWindow.swift` (`Review…` button; double-click opens
  Review when the session is labelled; the Delete Meeting alert gains "Also forget voice
  samples learned from this meeting"), `Sources/HolosApp/HolosApp+Meeting.swift` (the
  "Name Speakers — …" item opens Review and reports `reviewOpened`).
- Fill the "Review window (PR9)" section of `docs/meeting-validation.md`. PR9 merges
  last in wave 5 and writes the wave-5 `README.md` and `docs/status.md` notes for PR9 and
  PR11.
- Tests: `Tests/HolosMeetingTests/{ReviewSessionTests, AudioCompositionTests}.swift`.

**API.**

```swift
@MainActor public final class ReviewSession {
    /// Loads the snapshot off the main actor. `exportDelay` debounces export regeneration.
    public init(session: URL, profiles: SpeakerProfileStore?, maintenance: MaintenanceLauncher?,
                exportDelay: Duration = .seconds(2)) async throws
    public private(set) var snapshot: SpeakerSessionSnapshot
    /// What the window shows: updated at once by each edit (`SpeakerProjection.applying`), then replaced by the
    /// editor's result.
    public private(set) var projection: SpeakerProjection
    public var onChange: (() -> Void)?
    /// "Learn voices of people I name in this meeting"; defaults to the global "Remember voices" setting.
    public var learnVoices: Bool
    public func turns(matching query: String) -> [ProjectedTurn]            // case-insensitive text search
    public func nextUncertain(after turnID: String?) -> ProjectedTurn?        // wraps around
    /// Up to three clips from the speaker's longest non-overlapped turns:
    /// [start + 0.25, min(end, start + 4.25)], or the whole turn when shorter.
    public func sampleClips(for speakerID: String) -> [ClosedRange<Double>]
    /// The first 60 characters of the speaker's two longest turns.
    public func previews(for speakerID: String) -> [String]
    public func knownPeople() -> [SpeakerProfile]
    /// Edits run in order on a serial queue off the main actor (SpeakerEditor, regenerateExports: false).
    /// A refused edit reloads the snapshot and throws. Pushes undo; schedules exports.
    public func apply(_ actions: [SpeakerEditAction]) async throws
    public func undo() async throws                                           // this window's newest batch
    public func link(speakerID: String, to target: ProfileTarget) async throws   // learnVoice: learnVoices
    public func confirmAllSuggestions() async throws
    public func markSelf(speakerID: String) async throws   // passes learnVoices to VoiceProfileService.markSelf
    public func rejectSuggestion(speakerID: String) async throws
    /// `holos session diarize --keep-transcript --force --min-speakers <current + 1>`; names carry over (§4.9).
    /// Every relabel from here passes --keep-transcript: a meeting's languages are not detected again (§4.14).
    public func findMoreSpeakers() async throws
    /// `holos session diarize --keep-transcript --force --others-in-room` (call recordings).
    public func labelMicrophoneSpeakers() async throws
    /// Regenerates exports now if an edit is pending. Call when the window closes.
    public func close() async
}
public enum SessionAudioComposition {
    /// One composition track per session track; every chunk inserted at its session start time, trimmed so
    /// that no chunk overlaps the previous one.
    public static func make(session: URL, manifest: SessionManifest) throws -> AVMutableComposition
}
```

**UI** (`NSWindow` 1100 × 720, min 900 × 560, title "<name> — Review"):

```
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│ [Hide Speakers] [Next Uncertain] [Assign to… ▾] [Split Turn] [Speakers ▾] [🔍 Search] [Export ▾]│
├──────────────────────────────┬───────────────────────────────────────────────────────────────┤
│ SPEAKERS  [Confirm All (3)]  │ 01:12:03  [Jim ▾]         We should move the vote to next week. │
│ [Jim            ▾]    41:12  │ 01:12:40  [Speaker 3 ▾]   Agreed, but the budget…               │
│   "We should move the vote…" │ 01:13:05  [Unknown ▾]     …                                     │
│   ▶ Play samples             │                                                               │
│ [Speaker 3      ▾]    22:03  │                                                               │
│   Maybe Maria [Confirm] [Not Maria]                                                          │
│   This is me · Merge into… ▾ │                                                               │
│ Me                    15:40  │                                                               │
├──────────────────────────────┴───────────────────────────────────────────────────────────────┤
│ [❚❚ Pause]  1:12:03 / 2:58:12  ━━━━━━━━━━━━━━━●━━━━━━━━━━━━━━━━━━━━━━  [1.25× ▾]  Speaker 3     │
├──────────────────────────────────────────────────────────────────────────────────────────────┤
│ [x] Learn voices of people I name in this meeting    11 speakers · 343 turns · 5 changes · saved 17:12 │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

- Sidebar row: a name combo box (known people, most recently used first; Return links
  or creates the person; empty clears the name), talk time, the first 60 characters of
  the speaker's two longest turns, Play samples, a suggestion "Maybe Maria" with
  Confirm / Not Maria, "Jim (auto)" with Not Jim once calibrated, "This is me", Merge
  into… Speakers with no turns are hidden (except user-created ones).
- Turn row: timestamp button (plays from there), speaker pop-up (all speakers, known
  people, "Unknown", "New Speaker…"; first "Jim (suggested)" when a turn of the row
  sounds like Jim, below), text right after the pop-up (wrapping; a plain click on a
  word selects the turn and plays from that word, with the pointing hand over the text;
  ⇧/⌘ clicks, double clicks, and drags only select). Multi-select with ⇧/⌘.
- Paragraphs (`ReviewParagraphs`, HolosMeeting; pure): the transcript reads like a
  document, so a row is a paragraph of consecutive turns rather than one turn. A turn
  joins the row before it when it has the same speaker and starts less than
  `gapSeconds` (3 s) after the latest end of the row's turns; a different speaker in
  between ends the row. A named speaker's microphone and system-audio turns join;
  unknown-speaker turns join only on the same track (as in the exports), so an unknown
  microphone turn never joins a named or unknown system-audio one. The second part of a
  split ("T5/…") and a turn without a known start begin a row. A row shows its first
  turn's time, one speaker pop-up, and its turns' texts joined with spaces. Nothing on
  the row marks an uncertain turn (the pop-up already says "Unknown" where no speaker was
  found; a column of warnings beside it only repeated that): Next Uncertain finds them,
  and the pop-up's VoiceOver label says "Speaker, uncertain" when any of the row's turns
  is uncertain ("Speaker, overlap" when one of those overlaps), with why in its help and
  tooltip. When a turn of the row sounds like Jim, the pop-up lists "Jim (suggested)"
  first ("Jim (suggested for the part from 01:12:40)" in a row of several turns), named
  for the row's first such turn; choosing it gives that turn alone to Jim
  (`acceptTurnHint`), whatever else is selected, and VoiceOver hears "sounds like Jim" on
  the pop-up (that turn's own uncertainty gives way to it; the row's other turns' stays).
  Rows are only how turns are shown: edits still name turns, and the journal and exports are unchanged
  (Markdown and text already merge a speaker's consecutive turns into blocks, §4.11).
  Everything per word works across a row's turns: clicking a word, the word playing and
  following it, word-fix underlines, tooltips and Revert, VoiceOver's per-word actions.
  Assigning a row (its pop-up, Assign to…, 1–9, New Speaker…) gives every turn of the
  selected rows in one change, so one Undo restores them. Search shows the rows with a
  matching turn, whole; Next Uncertain goes to the row of the next uncertain turn after
  the selected rows' last turn and plays from that turn. Split Turn on a row offers its
  words: a word inside a turn splits that turn there (a `splitTurn` edit, undone as any
  other; its second part starts a row), and a word that already starts a turn only
  breaks the row before that turn, in this window (nothing is saved, so Undo has nothing
  to take back; the break belongs to the run it was made on and goes with its turn; a new
  run drops it (the speakers labelled again; turn IDs then name other turns), except the
  runs published while the window reverts word fixes, which keep the turns and their
  breaks; the window closed drops it too). A turn is split where its words are, as Otter
  does: in edit mode, Return with the caret at the very start of the field's words and
  nothing changed splits before them (the field opens with its word selected: ← first), and
  at the very end, after them; outside edit mode, a word's context menu offers Split Turn
  Here (none on a row's first word, nor in edit mode, where a field may be open), and
  VoiceOver's actions on the text offer the same as "Split Turn Before “word”". A split
  asked on rows of a labels run that was replaced since (Label Again, a refresh from
  elsewhere; not a run a word edit, its undo or a revert published keeping the turns) is
  refused when chosen and again when it runs (it may wait behind other changes), since a
  turn ID may name another turn by then. A split
  from the field refused once queued (an edit saved meanwhile changed what it can do) opens
  the field again over its words once the labels are read again, with the caret where
  Return found it and the reason (unless edit mode was turned off, another text field took
  the keyboard, or a word's field was opened meanwhile: the footer alone says why). A field opened while the split
  saves stays open as the split's saved turn replaces its temporary one, and the second
  part's speaker pop-up then does not open. A word two overlapping turns hold splits the turn it was
  chosen in. A short interjection shown with its neighbour's speaker splits as the turn it is
  stored as (inside it, that turn splits; at its first word, the row breaks before it). Both make the same split or break as the sheet, checked
  first as the split itself is (`ReviewSession.splitRefusal`: words edited together, a
  turn's first word, a review held read-only; refused, the banner or a disabled menu item
  says why, and the field stays), across a segment boundary too (the first word of a later
  segment of the turn). The place is the word as the list showed it, with the word moves
  and words epoch it was chosen under: the review finds where that word is now
  (`ReviewSession.splitPlace`; a word edit saved since moves it, one that replaced it or
  words changed elsewhere refuse the split), never an index read again. Then the second
  part's row is selected and its speaker pop-up opens, so it can be given its speaker at
  once; it keeps the first part's until then (a search hiding that row is cleared first).
  The edit-mode banner says so. The Split Turn sheet stays: it chooses a place by keyboard, and plays from
  it first. Joining rows is the inverse, as removing the line break between two paragraphs
  of text (2026-10-08): in edit mode, Backspace with the caret at the very start of a row's
  first word and nothing changed joins that row to the row before it, and forward Delete at
  the very end of a row's last word joins the row after it; outside edit mode, a row's first
  word offers Join With Previous Turn in its context menu and in VoiceOver's actions on the
  text (none on the meeting's first row, nor in edit mode). Anywhere else (inside a word, at
  a word inside a row, the word selected, something typed) Backspace and Delete edit the
  text as always. The rows are found among every row grouped, never the row a search left
  next to it (`ReviewWindow.joinResolution`); a join is refused as a split is (a review held
  read-only, labels run replaced since; the banner, a disabled item, or the footer says why),
  and at the meeting's first row (last, forward) the banner says there is nothing to join.
  When the rows' speakers differ, every turn of the later row takes the earlier row's speaker
  in one assignment, exactly as its pop-up gives it (`ReviewParagraphs.join`): ⌘Z gives it
  back, and voice learning treats it as any assignment. Either way the window joins every
  turn of the later row to the paragraph before it (`ReviewParagraphBreaks.join`, never
  saved, kept and dropped as the breaks are, and like them followed from a split part's
  temporary ID to its saved one; a join replaces a break before the turn and a break a
  join), so the rows read as one whatever kept them apart: a break made here, a split's
  second part, the 3 s gap, the unknown speaker's two tracks (a named speaker's microphone
  and system-audio turns given to the unknown speaker stay one row). Joins are only how rows
  read in this window, with the simplest life: made at once, and all of them dropped (rows
  then read as they group on their own) on any review-level Undo (⌘Z or the menu, whatever
  it undoes; a text undo inside a word's field, the search field or a name field is typing
  and leaves them), any change that fails or is refused (the save a close by hand makes
  too), any undo saved elsewhere (a command) that the window reads, and any relabel; nothing
  is put back. A join asked on rows of a labels run
  replaced since is refused, checked again as its assignment is queued. Joins dropped before
  the join's assignment came back (⌘Z pressed meanwhile) open no field and announce nothing.
  In a text field, ⌘Z undoes the field's typing while it has typing to undo (by its own undo
  history, never by comparing its text: "cat" typed over "dog" typed over "cat" is still
  typing), and also while a word's field holds text it did not open with (typing put back
  without its undo, after a ⇧-click widened the field or a save failed: ⌘Z then does nothing
  rather than undo the review's change behind it); only an untouched field (a word's field
  just opened, as after a join) hands ⌘Z to the review. A join whose speaker change comes
  back after a relabel opens no field and announces nothing.
  A row joined back to the part
  it was split from reads as before the split; the split itself stays in the journal (the
  journal's only way to take it back is a revert, which ⌘Z could not undo in turn), so ⌘Z
  still undoes it, and Markdown and text already merge the parts. Return at the same place
  breaks the row again. From the field, the field then opens again where the rows met (the
  caret at the start of the later row's first word, or at the end of the earlier row's last
  word for forward Delete, where that word is after word edits saved meanwhile, as a refused
  split's field does), so typing goes on there, unless the person went on typing
  elsewhere meanwhile; from the menu, the joined row is selected. While a join's speaker
  change saves, the field is closed, and a key pressed meanwhile in edit mode outside a
  text field (any key without ⌘, and ⌘← / ⌘→) beeps and does nothing: it never reaches the
  list or playback (Space, J, K, L), and nothing is kept to type later. Other shortcuts work
  as always: ⌘Z undoes the join at once, ⌘W closes. The field opens again when the save
  ends; a join dropped meanwhile (an undo here or elsewhere, a failure, a relabel) lets keys
  through at once, as it opens no field. The banner, and VoiceOver,
  say the rows were joined. After any
  change, a row stays selected only if every turn of it was selected: a turn that joins a
  selected row's paragraph clears that selection rather than widening it.
  While playing, the row of the turn being spoken is tinted, and a pause inside
  a row keeps it tinted with the last word spoken, so the tint and the scroll move a row
  at a time rather than every turn.
- Speakers pane (`ReviewPanes`, an `NSSplitViewController`): once the speakers are sorted
  out the pane can go. Hide Speakers / Show Speakers (the first toolbar button, View ▸
  Hide Speakers, ⌥⌘S; dragging the divider to the edge does it too) collapses it,
  animated unless Reduce motion is on, and the turn list takes its width; the window
  keeps its size. Speakers are still named, merged into, and assigned from each row's
  speaker pop-up. The state is per meeting (`ReviewSpeakersPaneMemory`: the IDs of the
  meetings whose pane is hidden, at most 500, in the app's defaults), so a meeting opens
  as it was left and a new meeting opens with the pane. Hiding it while a name is being
  typed there ends that field first (the window's field editor is found by its delegate),
  also when the divider is dragged to the edge.
- Short interjections (`ShortInterjections`, HolosSpeakers; pure, deterministic):
  presentation only, in the one view the list and the exports read. `SpeakerProjection`
  decides them after the echo mask (§4.9 step 7) into `interjections` and `shownTurns`;
  `turns`, `speakers` (talk time, turn counts), the run and the edit journal are left as
  they are, and edits, previews, Play samples, voice learning and voice matching read
  `turns`. A candidate is a shown turn of the unknown speaker of at most 4 words
  (`maxWords`; words are its text split at spaces, punctuation trimmed; the recognizer
  must also have timed at most 8, `maxRecognizerWords`, so a language written without
  spaces is not one long word) that the user
  did not assign (named by a `reassignTurns` edit in effect, Unknown included: choosing
  Unknown for an attached turn changes no stored speaker, yet it is saved, since
  `SpeakerEditor` compares `shownTurns` too, and keeps the turn unknown until undone),
  split (`modified`), or change a word of (a `reviewEdit` or `reviewRevert` fix made in
  Review, or a `liveCorrection` made while recording; automatic word fixes do not count).
  Spans from damaged files are counted without trapping (`recognizerWords`). Named speakers' turns are never candidates. Its neighbours are the turns just
  before and after it on its own track. In order:
  1. *Hidden* when every word is a filler or backchannel of the meeting's languages
     (`Transcript.languages`, else `locale`): in any language mm, hmm, mhm, mm-hmm, ok,
     okay; English um, umm, uh, uh-huh, yeah, yes, right, and "a" or "an" when it is
     the turn's only word; French euh, ouais, oui, d'accord. Letters held longer count
     as one ("Ummm", "Hmmm"). Fillers are never attached: a stretched "umm" heard as
     "an" belongs in nobody's sentence.
  2. *Attached* to the previous turn when that turn has a speaker, its text does not end
     a sentence (its last character, past quotation marks and closing brackets of any
     script, is a Unicode sentence terminal such as `.`, `?`, `。` or `؟`, or `…`), and the two
     adjoin: at most `gapSeconds` (1.5 s) of silence and at most `overlapSeconds` (0.5 s)
     of overlap between them. "…but they" + "agreed to it. Yeah." is the previous speaker's.
  3. *Attached* when the turns before and after it have the same speaker and it adjoins
     both: a few words inside one person's speech.
  4. Otherwise shown as it is. A short turn spoken over a longer one (more than 0.5 s of
     overlap) is someone else talking at the same time, never a continuation.
  An attached turn shows with that speaker (`ProjectedTurn.interjection`), so it joins
  their row and export block, and is uncertain only when it overlaps someone. View ▸
  Show Short Interjections (off by default, kept across windows) lists the hidden ones
  again as unknown-speaker rows; Next Uncertain skips them unless they are shown, and
  the footer counts them ("3 short interjections hidden"). While one plays it is the turn
  spoken (the bar says "Unknown speaker") and tints no row, as a turn a search left out,
  rather than passing for a pause inside its neighbour's row. The exports always leave them
  out, as they leave out echo, and write an attached turn with its neighbour's speaker
  (JSON adds `"interjection": "attached"` to it). The thresholds come from a meeting's
  rows where a lone "an" (a stretched "umm"), two standalone "Yeah." and four words that
  finished the previous speaker's sentence all showed as Unknown. Transcript files
  written before this change keep the old rows until they are next rewritten (the next
  speaker change rewrites them); a meeting with such turns has new summary lines, so its summary
  shows as out of date (§4.17).
- Playback bar (above the footer): Play/Pause, position / length, a scrubber, the speed
  (1×, 1.25×, 1.5×, 2×; remembered, pitch kept), and who is speaking. Playing goes on
  through the meeting until paused (only a speaker's samples stop by themselves); Play
  resumes where it paused, from the start once the audio ended. Once something played,
  the turn playing has a tinted background with an accent bar and its word a tint and an
  underline; while playing, the list keeps them in view, except for 5 seconds after the
  reader scrolls it (Play, a word, a timestamp, or ⌘←/⌘→ follow again at once). The
  words' times are the transcript's (estimated for old sessions). VoiceOver hears only who
  speaks, when that changes; a turn's text offers "Play from “word”" actions. Moving
  through the list with ↑/↓, Page Up/Down, or Home/End holds following off as a scroll does.
- Keys: Space (or K) play/pause, ←/→ (or J/L) 5 seconds back/ahead, ⌘← previous turn (the
  start of the playing one first), ⌘→ next turn — anywhere in the window except while
  typing in a text field (with keyboard navigation on, Space presses a focused button
  instead); Return in the turn list plays the selected turn; ↑/↓ move selection; 1–9 assign the selection to the speaker
  with that ordinal; ⌘' next uncertain; ⌘Z undo; ⌘F search; ⌘E edit mode (Editing words, below); ⇧⌘E export menu;
  ⌥⌘S hide or show the speakers pane. The app's View menu (shown while a window is open)
  holds Hide Speakers and Show Short Interjections for the key review window.
- Menu "Speakers": Confirm All Suggestions, Find More Speakers… (explains that names
  carry over and turn-level changes do not), Label Speakers on My Microphone (call
  recordings recorded without "others in the room").
- Export ▾: "Save As…" (NSSavePanel; Markdown, text, or JSON) and "Copy as Markdown".
- No modal prompts for voices: the footer checkbox decides whether naming a person
  learns their voice. Learning runs in the background after the name is saved
  ("Learning voices…" in the footer), never on the edit queue (§4.10, "Voices within one
  meeting").
- Voices within the meeting (§4.10): while the window is open it works out every turn's
  voice once ("Comparing voices…"); after a speaker is named, other speakers with that
  voice show "Maybe Jim" (Confirm / Not Jim, in Confirm All (n)), and a turn inside
  another speaker that sounds like Jim lists "Jim (suggested)" first in its speaker
  pop-up, which gives it to Jim in one choice. Speakers menu: "Merge Matching Voices
  Automatically" (off by default).
- Status line in plain words: "5 changes · 2 could not be applied (show)", "Your edited
  transcript.md was kept as edited-20260923-171200.md", "The transcript changed after
  speakers were labelled. [Label Again]", and "Audio deleted; playback is off."
- A dotted-underlined word changed by meeting word fixes has a contextual-menu and
  VoiceOver action to restore what the recognizer heard. It publishes a new transcript and
  immutable speaker head, carries the effective speaker edits over by timed word position
  (an order-preserving word difference for untimed segments), clears this window's
  speaker-undo history, and schedules fresh exports; it never diarizes. The restored words
  stay protected from automatic fixing until `session fix-words` is explicitly requested.
- Heavy work (snapshot load, edits, export regeneration) runs off the main actor (§1.3).
- The footer is redrawn on every change of the player's state (loading, ready, off and
  why), so "Playback is off: …" shows as soon as a first build fails.

**Editing words** (edit mode, 2026-10-06): fix misheard words and names where the text is
shown, Otter-style.

- *Mode.* "Edit Words" (a toggle in the toolbar, ⌘E; Export moves to ⇧⌘E) turns edit
  mode on: a tinted banner says "Editing — click a word to change it…" and the turn list
  is tinted. Off, a word click plays from it as before. On, a word click does not seek: it
  opens a field over the word, prefilled with it and selected. ⇧-click or a drag in the
  same row extends the selection, keeping what was typed in the field; it stops at the end of
  the word's turn and segment (the
  banner says so), since v1 edits one segment of one turn at a time. Return saves, ⌥Return
  saves and adds the new text to the word list, Tab saves and edits the next word, ⇧Tab
  the previous one, Esc cancels. Closing the window (or quitting) with the field open saves
  what it holds, before the close learns from the edits. Closed by hand (its close button,
  ⌘W), the window stays open until that edit is saved, and stays open when it is not (a full
  disk, a refusal): the field opens again with what was typed and the footer says why
  (`ReviewCloseGate`), so nothing typed is lost to a failed save. It waits the same way for
  edits handed over a moment before and still saving (Return, then ⌘W), and stays open when
  one of them is not saved. No field opens while it waits, so each edit not saved is kept;
  once the window stays open, the first one's field opens with what was typed and why, and
  the footer says the others, each with what was typed (`ReviewCloseRecovery`). Any edit not
  saved whose field cannot open again (a Tab past it, its words not shown, a close waiting)
  stays in the footer with what was typed (`UnsavedWordEdits`): the next edit never clears
  it; it leaves when "Edit Again" opens its field (the field's from then on: saved, or
  cancelled with Esc) or when it is dismissed. Closing the window by hand waits for them: it
  stays open, its footer asking to edit each again or dismiss it; quitting does not wait,
  and logs what was typed in each (private). Edits refused or failed while a quit closes
  the review are logged with what was typed (private), timeout or not
  (`failedWordEditsAtClose`). The field's edit such a close took is held on the window until it is queued, so a
  quit meanwhile closes the review with it, and no field opens while such a close waits. A Split Turn sheet's word follows a word edit
  saved while the sheet was open (`split(seen:)`), and is refused when the edit replaced
  it; a Revert's word likewise follows every word change saved since the words it was asked
  on were read. The window's list follows only the word moves the words shown are after
  (`shownWordMoves`): a move saved but not reread yet is not shown, and an open field never
  follows it onto the word that has its index now. Words changed elsewhere (a transcript this
  window did not make: `wordsEpoch`) have no word moves at all, so a field open across such a
  change closes saying what was typed (nothing saved), and a Split Turn sheet opened before
  it is refused; an edit handed over (or held by a close) carries it too, and is refused
  when the words were changed elsewhere meanwhile. A field opened again after a failed save
  follows its words through the moves saved since, never across such a change. A Review
  edit's mark exempts its words from echo filtering only when it lies within its segment. Quitting starts every review
  window's close at once (`ReviewQuit.closeAll`), so each queues its open field's edit before
  any slow close (another window's voice sync) is waited for; when the closes cannot finish
  within the quit's limit, every word edit not saved yet is logged with what was typed (as
  private): those Return or Tab handed over and still waiting or saving, and the one the
  field held at the close (`ReviewSession.unsavedWordEdits`). Return and Tab hand the edit to
  the review's queue before anything else runs (`queueWordEdit`), so a quit right after
  finds it there and the close saves it. A maintenance
  command that makes the review read-only does the same: the open field's edit is queued
  before the pause and waited for; when it is refused, the footer says why, with what was
  typed (`ReviewSession.pause(typed:)`). So does any other turn to read-only with the field
  open (Tab saved an edit whose labels could not be reread, `reloadProblem`): the field's edit
  is queued (`editWords(whileUnread:)`) and waits for the reread as the changes before it do;
  it is checked against the words shown when it was asked for (the transcript read before the
  unreread change), following that change's word move. When it is refused, the field opens
  again with what was typed, or the banner says it. The rule is general: only Esc drops what
  was typed. However else the field closes (edit mode turned off, a search filtering its row
  away, its words moved or gone, the review turned read-only), its text is queued as an edit
  (`TurnListView.keepWordEdit`), and the review's queue keeps it, saves it, or refuses it
  saying what was typed. A queued field edit, on every path (save, pause, close), carries its
  words' text as the field showed them, untimed punctuation included (`ReviewWord.shown`,
  `editWords(expecting:)`): a change made elsewhere and read since that kept a word's place
  but changed it ("Hello." to "Hello?") refuses the edit, saying what was typed, never writing
  over it. A ⇧-click that cannot grow the field (onto a word that cannot be edited) leaves the
  field as it was, with what was typed and its selection, and the banner says why. The field is
  at least 90 pt wide, so it can lie over the next words: a ⇧-click there passes through it to
  the table (`WordEditField.hitTest`, outside `wordsFrame`), which extends the selection; a
  plain click there edits the field's text. A head made elsewhere that lands between an
  edit's save and its reread empties the undo stack and gives that edit no undo entry either
  (`Operation.overtaken`). An undo that fails can be asked again while the labels are still
  this window's own (the same run, or one its word changes retargeted), and, for a word
  edit's undo, while that edit's transcript is still current (once another change replaced
  it the undo can never be made, and put back it would block every undo before it). A word
  edit's new run records the labelling it keeps (`DiarizationRun.labelling`): voices learned
  from the run before are that labelling's own, never kept as an earlier labelling's. Such a
  voice is compared by the audio it was learned from (`VoiceEnrollment.AudioInputs`: the
  speakers and their qualifying turns' tracks and times, read from the run it was learned
  from when that run still gives its input digest; times compared within a microsecond,
  never by a hash, so a time worked out again from the same words, 6.719999999999999 for
  6.72, is the same audio): the same audio keeps it as it is, also
  with the audio deleted; other audio recomputes or removes it, as for the head's own. The run
  is read through the current echo mask and, with one, without it (a sample learned before
  the echo was found): a mask found since that cuts a turn the sample was learned from is
  other audio. When the run can be read but no view of it gives the sample's input digest,
  its inputs changed: it is learned again, or removed (Remember voices off too), and the echo
  catch-up's check (`samplesOutOfStep`) reports it. Only when its provenance cannot be read
  (the run or its words cannot be read, a sample with no input digest) is it kept unless it
  can be learned again, or the person has no qualifying turn left. A
  word change keeps a turn's times when its words keep theirs (`Mapping.sameTimes`): a
  labelling may time a turn otherwise than by its words, and a voice was learned from those
  times. Every save of a field's edit (Return, Tab, a close, a pause, a turn to read-only)
  compares the `wordsEpoch` the field opened under, never the review's at the time of the
  save. The check before a field opens (`ReviewSession.wordEditRefusal`) and before Revert is
  offered (`revertRefusal`) is the save itself made as a dry run, on the transcript shown and
  the revision it was fixed from, in memory: the edit's request checks and
  `SessionWordEdit.edited` (what `SessionWordEdit.run` makes, with a placeholder for the
  text), and `SessionWordFixRevert.reverted` (the same for the revert; for a Review edit, the
  edit back to its `heard`). What needs the whole meeting is read once per labels read, off
  the main actor (`ReviewSession.WordChecks`): the unfixed revision, whether a segment ID is
  used twice, and the labels' plan onto the transcript itself, mapped by time as a revert's
  is (so a revert the labels cannot be mapped across, another segment damaged, is not
  offered). A click reads no file and makes no plan: a meeting of 30,000 words in 1,000 turns
  answers at once. Reads are coalesced: one at a time; the labels read again while one runs
  make exactly one more once it ends, for the labels then (never one per reread). A review
  closed meanwhile cancels its read, which stops at the next segment, turn, or speaker edit. While the checks are being read (after any change, for a moment), fields
  open and Revert is offered, and the save, which makes the full plan, decides, keeping what
  was typed when it refuses. Mapping the labels is linear in the words: each turn's spans are
  mapped through an index of the words' owners made once (`Mapping.spansAllowingEmpty`), and
  a segment the change left as it was keeps its words' owners without a time mapping. Whatever the save would refuse (a damaged revision or a segment ID used
  twice, `TranscriptWordEdit.structureRefusal`; a word corrected while recording; a fix a
  newer version wrote; an automatic fix whose count of recognizer words does not hold what it
  matched, older or modern; overlapping turns), the check refuses with the same message,
  before anything is typed. Only what depends on the text typed (where a deletion goes) is
  known at the save alone. Each result is kept per selection (or word) until the labels are
  read again or the labels shown change, so clicks stay cheap. A Review edit's `heard` is
  what the recognizer wrote as it was, whitespace and line breaks included (only trimmed):
  its Revert writes that back exactly (`Request.verbatim`), while learning and the menus
  read it with each run of whitespace one space. Space still plays and pauses outside the field; the
  timestamp buttons still play. Every word has a VoiceOver action "Edit “word”", which turns
  edit mode on and opens the field; it is offered only while words can be edited (not after
  the transcript changed under the labels), and reports failure when no field opened. An edited word is dotted-underlined like a fixed word
  ("You changed “heard”"), and its Revert ("Revert to “heard”") is another edit back to what
  the recognizer wrote; an edit is a change when its text as shown differs from what was
  heard, punctuation included ("Hello." → "Hello?"). A live hint replayed later (recovery)
  never marks or changes words edited in Review, nor a fix reverted there (`reviewRevert`): the
  hint is skipped. A head left to repair after a revert is repaired only onto the transcript
  the journal says was reverted from the one the window showed (`revertedFrom`), as an edit's
  is. Words edited together that a relabel (Find More Speakers, Label
  Speakers on My Microphone) has since put in two turns offer no Revert (menu or VoiceOver)
  and open no field (an edit takes in the whole mark, across the turns, and would be
  refused; a selection stops before them); their tooltip and the banner say so, and that the
  other words of each turn can be edited (`ReviewWord.revertible`). Relabels are not stopped
  from splitting them. Revert (of an edit or of an automatic fix) is offered only while words
  can be edited, since otherwise it would be refused. Words known not to be editable open no
  field either, and the banner says why (`ReviewSession.wordEditRefusal`, the save as a dry
  run): a word corrected while the meeting was recording, words that do not all belong to the
  same speaker turns (overlapping turns hold only some of them: the new words would belong to
  every turn of every word replaced, and the undo could not give each back to its own;
  checked on everything an edit takes in), a segment with an automatic fix that cannot be
  counted. A save refused or failed after Return never loses what was typed: the field opens
  again over the words with it (when they still read the same and no other field is open),
  and the message says what was typed in any case, also for a queued edit refused later. It
  is said once: in the banner over the field that opened again, as every refusal before a
  field opens is, else in the footer (kept until edited again or dismissed). Nothing typed
  (a deletion) adds no "What you typed: “”".
  ⌥Return's word-list term is added once the edit is saved, also when the labels could not be
  refreshed after it. ⌘E turns the mode on only while words can be edited
  (`ReviewSession.canEditWords`): the review is editable (no command holds it read-only), its
  labels were made on the current transcript (after the transcript changed, the banner says
  to use Label Again first), every speaker change can be read (a damaged or newer line in
  the journal: each edit carries them all over, so it would be refused), and the revision the
  transcript was fixed from (`fixedFrom`) can be read (every edit and revert reads what the
  recognizer wrote there; checked once per labels read, `baseUnreadable`). The Edit Words
  button's tooltip, and the banner in edit mode, say which; no field opens. It always turns
  it off.
- *The words' text.* An edit replaces, and the field starts with, the text the words show
  in the transcript and the exports (`TranscriptWordEdit.shownText`): from the first word's
  offset to the next word's, without the whitespace at either end. So punctuation the
  recognizer did not time goes with its word ("Hello" timed in "Hello." shows and is edited as
  "Hello."), and the space Apple's recognizer puts at the front of a word's range (" cloud")
  stays in place ("ask Claude now", never "askClaude now"), in the base revision too.
- *The open field* follows its words. Tab opens the next word's field before the save of the
  last one ends; every saved edit and undo records how it moved its segment's words
  (`ReviewWordMove`: the selected word indices and what replaced them, the rest shifted; the
  words a span took in around the selection, the rest of a fix or a deletion's neighbour, keep
  their own place), the field maps its words through the moves since it opened (a word merged
  by a deletion, whose time changed, is found all the same), and so does a queued edit when it
  runs. The words must still read the same as shown (a neighbour a deletion merged into loses
  the space Apple put at the front of its range, and is the same word), and a word a move
  replaced is never followed onto
  another word: the field closes and the banner shows what was typed (a queued edit is refused
  saying it). While the labels could not be reread after a change, every queued change (a word
  edit, a rename, an assignment, an undo) waits; only the reread (a reload) and the transcript
  files run ahead; a relabel runs only once the changes queued before it have (its labels
  would make them stale), and the changes run after the reread. After the column width or the row heights change, the field
  is put back over its words.
- *What an edit is.* `ReviewSession.editWords(refs, to: text)`: shown words (stored
  `WordRef`s, so a word the echo mask hides is never named, §5.11) of one segment, in a row,
  replaced by any text: more or fewer words, or nothing (a deletion). The refs must be
  consecutive stored indices of words shown in one projected turn; hidden echo words between
  them, another segment, or another turn refuse the edit with a message. The span grows to
  whole word-fix marks it touches (a mark is never split), and a deletion is merged into the
  next word of the same turn (else the previous one; each judged with the marks it would take
  in, so one whose fix runs out of the turn, or holds a live correction, gives way to the
  other), so the deleted words keep provenance
  and time: "I um think" with "um" deleted is "I think" whose "think" was heard as "um
  think". Deleting every word of a segment removes them with it (*Deleting a whole segment*,
  below). Touching a live correction (`liveCorrection`, whose live hint would no longer
  match) is refused in v1, a whole segment's deletion included; so is deleting words whose
  segment's other words are another turn's or hidden echo, which neither a neighbour nor the
  whole segment can take ("These words can be deleted only with a word beside them in the
  same turn, or with every word of their segment"). Whitespace in the new text collapses to
  single spaces; an edit that changes nothing saves nothing.
- *Deleting a whole segment* (2026-10-08): a word the recognizer heard from line noise is
  often a segment of its own ("That sounds fine? Thanks," with "Thanks," a segment):
  selected whole and deleted, there is no word of its segment to carry it, so the segment
  loses every word.
  - *Transcript.* The segment stays (its ID, times, track, and language: turns, the event
    log, and every map by segment ID still find it) with no text, words, or fixes, and what
    it held is kept beside it, `TranscriptSegment.removed` (`TranscriptRemovedWords`: the
    text, the timed words, and the fix marks as they were). A segment with `removed` and any
    text, word, or fix of its own is damaged (`isDamaged`). The deletion is made in both
    layers, as any edit is, and both keep one record: the unfixed words, and beside them
    (`TranscriptRemovedWords.fixed`) the fixed ones with their automatic fixes. Word fixes
    made again from `B′` copy the segment, record and all, so they keep it empty (nothing to
    fix there) and a Restore in the fixed revision they make still brings back the fixed
    words. Like any edit, the deletion of a fixed segment is refused when its fixes do not
    lie over the unfixed words as recorded (`baseBounds`: a wrong `heardWords`), since the
    two could never be restored together. `hasReviewEdits` counts it, so deep transcription and language
    detection do not replace the transcript unless forced. `Transcript.text` and the
    speaker-less exports leave such segments out (no double space).
  - *Labels.* The word move is the segment's every word replaced by none (`0-n` → `0-0`,
    the same journal fields, so a head owed after a crash is repaired from it). Mapped by
    it, the turns lose the segment's words; the run records which turns held them
    (`DiarizationRun.removedSegments`, `RemovedSegmentTurns`), with each one's words and
    times just before (`before`): a turn holding those same words again when they come back
    takes those times again, never times worked out from the words, so a deletion and its
    undo or Restore leave every turn's times, and what is learned from them, as they were.
    Several segments deleted from one turn come back in any order: a Restore hands its
    snapshots on to the segments of the same turns still deleted, so once every word is back
    the turn matches the snapshot taken before the first deletion.
    A turn left with no word
    stays in the run with no spans, keeping its ID: speaker edits naming it (an assignment, a
    new speaker) carry over, and its words come back to it. The projection shows no turn
    without words, as it shows no turn of echo alone: it counts for no speaker
    (a speaker with no other turn is not listed, unless made in Review), and no list or
    export has it (§4.9 step 6). Every other plan keeps such a turn as it is (mapped by time, a turn with
    no words stays with none). A split made in Review whose word was in the deleted segment,
    or whose first part would be left with no word, cannot be carried over, and the deletion
    is refused saying so.
  - *Undo and Restore.* The undo restores the transcript as it was (a copy of `C`), and the
    inverse move gives the words back to the turns recorded. Later, in another window too,
    the turn shown nearest the deleted words in time (of their own track first) offers
    **Restore Deleted “Thanks,”** in its words' context menu and as a VoiceOver action, while
    words can be edited (`ReviewSession.deletedWords(near:)`, `restoreDeletedWords`). Since
    that needs a turn shown (every turn around the words may have gone too), **Edit ▸ Restore
    Deleted Words…** lists every deleted segment that can be restored ("00:10  Restore
    Deleted “Cheers.”", in a menu over the Edit Words button; `deletedWords()`), enabled
    while there is one. A Restore is an edit like any other (`Request.restoresRemoved`) that
    puts back exactly what `removed` kept in both layers (a fixed revision the fixed words,
    unless they no longer lie over the unfixed ones, which then come back in both; refused
    when what was kept is damaged), and one undo takes it back. For the window it is a word
    edit, made the one way every edit is (`ReviewWordEditCoordinator.track`): offered and made only while a
    field could open (not while a close by hand waits for earlier saves), queued in the review
    at once (`queueRestoreDeletedWords`), saved once its `committed` says so (also when the
    labels could not be reread afterwards: the words are back), and tracked, so a close by
    hand right after waits for it and stays open when it was not saved (the footer says why;
    nothing was typed, so it is never held as an edit to type again), and a quit closes the
    review with it queued, a failure logged with the other word edits
    (`failedWordEditsAtClose`). It is offered only while the run records the turns that held the
    words: after Label Again (a new labelling, which gives the empty segment no turn) the
    words stay deleted.
  - *Learning.* Nothing: the segment keeps no mark, the edit is a deletion, and no correction
    whose value is empty is ever taught (`ReviewLearning.corrections`,
    `CorrectionList.learnFromReview`). No word-list term is offered either.
  - *Older builds.* An older Voice is Local ignores `removed` and `removedSegments`: it reads
    a segment with no words (shown and exported as nothing) and a turn with no words (a
    blank row in its Review). It does not know the segment as a Review edit, so a forced
    or automatic pass it runs may replace the transcript, and its writes drop the record: the
    words then stay deleted with no Restore.
- *Revisions* (`TranscriptWordEdit`, pure; `SessionWordEdit`, published). The edit is a fix
  of a new kind, `reviewEdit`, whose `heard` is what the recognizer wrote over the whole span,
  exactly as the text had it, so a Revert writes it back unchanged ("你好世界" stays without a
  space, "hello — there" keeps its dash): unmarked words as shown, the text between pieces as
  it is, an automatic fix it absorbed the recognizer's words it stands for in the base (the
  punctuation outside the phrase it matched included, so "Claude." edited and reverted is
  "cloud." again), a Review revert's restored words as shown. How many recognizer words that
  is goes beside it (`TranscriptWordFix.heardWords`, recorded only when it is not the count of
  whitespace-separated tokens of `heard`), so `heard` stays in the unfixed word space every
  provenance map uses (`WordFixStage.wordOrigins`, `SpeakerTranscriptRetarget.origins`: its
  original word count is `heardWords`, else `tokens(heard)`; `WordFixes.originalWordRanges`:
  like a live correction, the base already holds it). Every Review edit, automatic fix
  (correction, term), and live correction written from this version on records `heardWords`
  (for an automatic fix or a live correction, the words it touched: "你好世界" over two timed
  words, "type c" in "“type c”" over two, "hello — there" over two; a live correction across
  language pieces adds those of a deleted piece it carries), the one source of truth. An older fix without it is counted by the whitespace-separated
  tokens of its `heard`, as before. The count is read only through
  `TranscriptWordFix.heardWordCount(within:)`, nil when it cannot be right (not positive, more
  words than `heard` has characters, more than the words left where it stands; compared
  without adding, so a damaged `Int.max` never overflows); a fix whose recorded count is not
  right is not sound (`isSound`), like a mark past its segment's words. *Limit:* an older automatic fix over text without spaces
  between its words (Chinese, Japanese) is then counted wrong, and an edit in its segment is
  refused with "This segment has a word fix made by an earlier version of Voice is Local,
  which edits cannot work around yet" (`TranscriptWordEdit.olderFix`); its Revert fails as it
  did before this version. No write counts words by splitting text at its spaces: an edit and
  an automatic fix record the words they replaced (`heardWords`) and are their mark's words;
  the Revert of an automatic fix brings back the recognizer's own words from the base, with
  their text, times, and boundaries ("你好世界" is "你好" and "世界" again), and a revert kept
  on a new base keeps the words already there; the Revert of an edit is another edit. The
  edit is made in both layers:
  - the unfixed base `B` (`current.fixedFrom`, or the current transcript when it has none)
    gets a new revision `B′` with the edit marked `reviewEdit` (its new words as `C′` has
    them, so both count the edit's words alike even where one would keep the recognizer's
    words for the same text and the other split it anew), `fixedFrom` nil and
    `liveCorrectedFrom` = `B.liveCorrectedFrom ?? B.id` (the stable word space retargeting
    compares);
  - a fixed current transcript `C` gets `C′`: `C` with the same edit, `fixedFrom = B′.id`;
    its other fixes stay where they are.
  An edited span keeps the original span's start and end: in a timed segment its new words
  share that time evenly (`WordFixes.applying`); an untimed segment stays untimed, so its
  words keep estimated times. Because the edit lives in the base, every later word-fix pass
  starts from `B′` and keeps it (a `reviewEdit` mark is never replaced by a correction or a
  term). Deep transcription and language detection refuse to replace a transcript that
  holds Review edits unless forced, as for edited speaker labels (the edits are then lost).
- *Publication* follows `SessionWordFixRevert`: the processing lease, the writer lock, then
  the speaker lock; the current transcript and head run must be the ones the window showed;
  the words must still be shown in the head's projection (echo mask included); the speaker
  run is retargeted (`SpeakerTranscriptRetarget.plan`: turns keep their IDs, effective edits
  are replayed with their IDs and batches) and staged. An edit's words map by index, never by
  time (`labelsMove`: the edited span, with any neighbour a deletion merged into, and its
  replacement): every other word keeps its exact owner, and the replacement words take the
  edited turn; recognizer timings of neighbouring words can overlap across speakers, and a
  time mapping gave such a word to both turns. Automatic word-fix stages still map by time.
  `B′` is saved as a revision with a `transcriptEdited` event (`transcriptID`, `base`,
  `segment`), then `C′`'s `transcriptEdited` event (also `replaced` and `replacement`, the
  move, which a repair maps by), then `C′` becomes current, then the new head. `unfixedID` follows
  `transcriptEdited` like `wordsFixed`. A head that could not be published is repaired from
  the old head as a revert's is. When that repair fails too (after an edit, its undo, or an
  automatic fix's revert), the head is owed: the window
  stays read-only with a banner saying so, Reload repairs it first, and no reread (Reload, a
  relabel) resumes the review until the labels are on the current transcript (labels made on
  the words as they were would make the edit's undo fail and Label Again drop turn edits);
  when the app quits in between, post-processing repairs it
  first (`SessionWordEdit.repairPendingHead`, before any stage may replace the transcript or
  relabel over the old head, the only copy of the turn edits). Every Review change that moves
  the transcript pointer (an edit, its undo, an automatic fix's revert) records `headFrom`,
  the transcript it was made from, in its journal event, so the head it owes is found
  whatever the event's kind (an edit's word move maps the labels; a revert's map by time).
  Exports are regenerated
  `exportDelay` later; the summary is no longer current (its key holds the transcript ID).
  Speaker labels, speaker edits, and the window's paragraph breaks survive (a run an edit or
  its undo published is known to keep the turns, `ReviewSession.keepsTurns`; the labels
  reread afterwards are the edit's own only when their run is that one, so a relabel saved
  elsewhere in between is a change made elsewhere); the playback
  and highlight mapping is rebuilt from the new segments. What the window keeps of a
  committed edit (its undo, its word move) is recorded as soon as the transcript is current,
  even when the labels cannot be reread then, or when saving the transcript failed after its
  pointer was renamed into place (the head is then owed, as above); an edit, its undo, and an
  automatic fix's revert all save through `TranscriptPointerSave`, which reports such a save
  as committed, never as a refusal. Split Turn is refused
  inside words edited together, so their edit and its Revert stay in one turn.
- *Undo.* An edit is one entry of the window's undo, among speaker changes; it keeps the undo
  history (the retargeted run keeps every edit ID and batch). An automatic fix's Revert is not
  undoable, but it is this window's own change too: its run keeps the speaker changes' undo,
  changes queued while it saves follow its word move (an edit of the reverted words is
  refused, saying what was typed), and the word edits' undo entries go (each needs its own
  transcript current). Undoing an edit
  publishes a copy of `C` (new ID; `fixedFrom` still names `B`, so `B′` is left unused) with
  the head retargeted again by the inverse move: the text, words, timing, and fixes are
  exactly `C`'s, every word is back with its owner, and speaker edits made since carry over. It is refused when the current transcript is no longer the
  edit's `C′` (or the copy an undo made of it); once a reread finds the labels on a
  transcript that is no longer current (another process replaced it), the word edits' undo
  entries are dropped, so undo reaches the speaker changes before them. A speaker split waiting in the queue whose
  word is in the edited segment is refused (its word index may have moved).
- *Echo.* Words under a `reviewEdit` mark are never echo (`EchoFilter.reviewEditedWords`):
  the acoustic mask never hides them, and the text filter of a new run (Find More Speakers,
  Label Again) neither drops them nor lets a run pass through them (they stay in the sequence,
  matching nothing, even an edit with no letters such as "…"), so correcting "write" to "right"
  beside the call's "that sounds right", or "rarely" to "really" in "I rarely think so" beside
  its "I think so", hides nothing. The person read and confirmed them. Their ranges are read
  only within their segment's words.
- *Learning* (`ReviewLearning`, `TranscriptEditLearning`; the app's learner). Corrections are
  learned when a review closes (also when the app quits, which closes its reviews), from
  every word you edited in that meeting; an existing correction for the same phrase is kept.
  Nothing is learned while editing, so nothing is ever taken back. What each meeting's closes
  taught is kept in corrections.json itself, beside the rules (`CorrectionList.reviewTaught`,
  meeting ID → its lessons, one value per phrase), and written in the same atomic save as the
  rules under the list's lock: a rule and the record that the meeting taught it can never
  disagree, so no close stopped part way needs repairing. A close teaches only what the
  meeting has not taught, so a correction you delete or change in Corrections (which removes
  or changes the rule, never the record) is not taught again by the meeting:
  - the edits are every `reviewEdit` fix of the transcript as it is then; an edit undone or
    reverted is not there, so it teaches nothing. Edits side by side in one turn are one
    phrase: "bull" → "pull" then "requested" → "request" teaches "bull requested" → "pull
    request" (what the recognizer wrote, from each edit's `heard`), never "pull requested" or
    "bull request", which would match nothing it wrote. Only edits that change words are
    joined: one changing only punctuation or case ("Hello." → "Hello?") is learned on its own
    and stands beside the other as it is now shown, so "Hello. cloud" → "Hello? Claude" never
    teaches ". cloud" → "? Claude". An edit (or such a phrase) is learned
    only when one turn holds all its words, and its context comes from that same turn (turns
    may overlap: two turns each holding some of the words are not one), across segments too:
    at a segment's edge, the context is the turn's word beside it in the segment its spans go
    on in (a one-word segment inside a longer turn has context), never across hidden echo.
    Words edited together
    that a relabel has since put in two turns are not learned (a correction would mix two
    speakers' words); an edit beside them is learned on its own;
  - each is diffed as dictation's Learn does (`CorrectionList.learn`, the recognizer's words
    against the words' shown text, one shown word on each side as context so a lone
    dictionary word is learned only with its neighbour: "cloud now" and "cloud later" are two
    phrases). A neighbour is context only when it is shown in the edited word's own turn, as
    an edit itself may take in: never the next speaker's word at a turn boundary, nor a word
    hidden as echo; without such a neighbour the rule learns as it does without context. A
    neighbour under a fix (automatic, live) stands with its whole fix, and the heard side
    takes what the recognizer wrote there: beside "cloud" fixed to "Claude", "as" → "ask"
    teaches "as cloud" → "ask Claude", which matches the recognizer's text. Both sides cover the
    same characters: an automatic fix's heard side is the unfixed revision's text over the
    extent shown ("cloud." beside "Claude.", the period untimed); when that cannot be read,
    its `heard` only if its shown text is just its words, else no context. A fix the edit's
    turn holds only part of gives no context on that side (corrected text never stands for
    what was heard: "as New" beside "newark" made "New York" would match nothing), nor does a
    damaged one (its words out of the segment's, `TranscriptWordEdit.isSound`, the one check
    every walk over a fix's words makes first; it is never read). Two marks over the same word
    (each in range on its own) are damaged too: each word has at most one fix. So is a word
    whose range does not fit the text, starts before the previous word ends, has a boundary
    inside a character written as a surrogate pair, or reads otherwise than the word's text
    (`TranscriptWordEdit.isDamaged`). A transcript with two segments under one ID is damaged
    as a whole (`hasRepeatedSegmentIDs`: which words are meant cannot be told): no word of it
    is edited, and close-time learning reads nothing from it. A damaged
    segment shows no marks and none of its words is edited or reverted: the refusal comes before
    a field opens (`wordEditRefusal`, with the reason in the banner), before any range is
    walked. Close-time learning skips it, and reads no context from a damaged unfixed
    revision; editing and reverting refuse a damaged unfixed revision. A fix of a kind a newer
    version wrote is never read as what the recognizer wrote: learning reads the editor's kinds
    only (`TranscriptWordEdit.editableKinds`, and a live correction), and skips a segment
    where an edit holds or stands beside such a fix. Every word range read
    from disk is made one way (`utf16Range(offset:length:within:)`: by subtraction, never past
    the text, never backwards), so no damaged offset or length can overflow or trap. A word
    move in the event log is read only as written ("3-5", two unsigned decimal numbers; never
    empty, but for a whole segment's words deleted or restored, every one of its words to or
    from "0-0", the segment holding `removed` on the empty side and not on the other; at
    most a million replaced × replacement word pairs, far more than any edit of one
    turn; its replaced words all of the same turns, checked wherever a move is mapped; a
    segment both revisions have, every word outside it reading the same in both; the edit's
    `reviewEdit` mark exactly over its new words, or, for an undo (the event says `"undo":
    "1"`), over the words it replaces, each direction checked on its own side, so repeated text
    or an older mark elsewhere never passes for it): a
    malformed one makes the event damaged, refused rather than read another way. An automatic
    fix's words in the unfixed revision must hold what it matched (`heardFits`: its `heard`
    touches the first and the last, and no word around them, untimed punctuation it matched
    included: "hello." over the timed "hello"; found in one linear pass), so word counts that
    are wrong but add up never put a fix over other words; mapping speaker labels by those
    counts (a word fix run, no word move) checks them the same way when the unfixed revision
    can be read, and refuses them when they are wrong. Every walk over a segment's words
    (a turn's words, close-time learning) reads the segment once and looks words up by index,
    so a very long or crafted segment never takes more than linear time; learning indexes the
    turns' spans by segment once and skips segments with no edit. Mapping speaker labels by
    time refuses a transcript with a damaged segment or a segment ID used twice. The
    turns are the labels on the transcript as it is then: labels the window could not reread
    after an edit are read again at close; when that fails, or the labels read are still on
    another transcript (a speaker head owed, or the transcript changed under them), nothing
    is learned at this close (logged; a later close learns the same edits);
  - the pairs go to `corrections.json`, the list Corrections (⌘2) shows
    (`CorrectionList.learnFromReview`, then `learnReplacingTaught`): a lesson the meeting
    taught already (same phrase and value) is skipped; a phrase the list lacks is added; one still
    holding the value this meeting taught it takes the new one (the word re-edited from
    "Claude" to "Claudia"); one holding anything else keeps it (an external or another
    meeting's choice wins; within one close, the first in the meeting); nothing is removed.
    Only what the close put in the list (added, or replacing the meeting's own earlier value)
    is recorded as taught, one value per phrase; a rule the list already held unchanged is not
    the meeting's, so a later re-edit there never overwrites it. A write that fails (logged)
    changes neither the rules nor the record, so the meeting's next review close makes it
    again, since the edits stay in the transcript. Dictation and Corrections read only the
    rules. An older Voice is Local reads the file as before (it ignores the record) and, if it
    saves the list, drops the record: the meetings could then teach a rule deleted since
    again. `review-learned.json`, which only builds of this change's development wrote, is
    ignored (never shipped, so nothing to migrate);
  - the write is one step under the meeting's speaker lock, off the main actor. The labels
    are read again in it (transcript, head run, speaker-change journal) and must give the
    edits the corrections were made from (the corrections are those edits taught by the app's
    rule, which needs the main actor's spell checker, so the edits, not the rule, are derived
    again): a replacement, a relabel, or a speaker change (a split) since teaches nothing at
    this close (logged; the next close learns from the labels as they are then). Then
    corrections.json is read, changed (rules and record), and saved once under its own lock
    (taken inside the speaker lock; nothing takes them the other way round). The app takes the
    list again afterwards;
  - nothing is learned from a deletion (a whole segment's leaves no mark at all; no
    correction whose value is empty is ever taught), a punctuation-only change, or a
    case-only change (decided on the edited words alone: a context word's own fix never makes "Hello" →
    "Hello," teach "Hello cloud" → "Hello, Claude"), unless the case change makes a proper noun (a word whose lowercase is not a dictionary
    word: "github" → "GitHub"), which teaches only the casing, never punctuation changed with
    it ("github," → "GitHub." teaches "github" → "GitHub"); words split or joined ("everyday" → "every day") are a real
    change;
  - when the new text looks like a name or term (a word that is not a dictionary word, has a
    capital inside it, or a content word the edit capitalized: each word compared with the
    heard word it stands for, so "APPLE" → "Apple" is not, and the second of "Apple apple" →
    "Apple Apple" is), the window offers "Add
    “Claude” to the word list, often heard as “cloud”?" (Add / Not Now); ⌥Return adds it
    without asking. Both keep the punctuation that belongs to the term and drop the
    sentence's (`WordList.typedTerm`): "C#", "C++", ".NET", "Node.js" stay; "GitHub," and
    "Claude." lose the comma and period (a final period only when the rest of the word is
    plain, so "e.g." keeps it, or follows a closing quote or bracket: "(Claude)." and
    "“Claude”." give "Claude", "(Node.js)." gives "Node.js"). What was heard is cleaned the same way before it is compared
    with the term, so a case-only change ("c#" → "C#") gives no "often heard as", never the
    broader "c". Nor is what was heard over words holding a deletion ("Clyde" edited over a
    word "um" was merged into would give "um cloud"): the term may still be offered, with no
    "often heard as" (`Result.holdsDeleted`). The term is what was typed, never words the edit took in around it
    ("Yorkshire", not "New Yorkshire", when only "York" of an automatic "New York" was
    edited), and "often heard as" is given only when the recognizer's text for exactly those
    words is known. "Often heard as" is the recognizer's text unless it is the term itself in
    another case;
  - a word-list term added from the offer stays (an explicit action). A correction learned
    stays until removed in Corrections.
- *Not in v1.* Editing while the meeting records (Review opens after it), spanning segments
  or turns, editing over a live correction, redo, and showing the edit before it is saved
  (the field closes and the row updates once saved).

**Saving, undo, and rereading** (`ReviewSession`): what the window shows always matches
the disk.

- An undo takes its change off the undo list at once and puts it back in its place when
  it saves nothing (a journal that cannot be written, a refusal). An undo of a change
  that saved two batches and failed after the first is put back whole; the next undo
  reverts what is still in effect. An undo of a change still saving that fails shows the
  change again and keeps it undoable.
- A change whose lines were saved but whose labels could not be reread stays shown, and
  the review turns read-only with a banner ("The change was saved, but the window could
  not reread the speaker labels: … [Reread]") until a reread works; that reread finds the
  change's lines and makes it undoable. The same holds when a relabel, or labels changed
  elsewhere, cannot be reread.
- Every reread of the labels (a reload, a refusal, a relabel, a saved change's result)
  rereads the people first and builds the labels with their names, so automatic names
  and the name list agree after a rename in People or the CLI.
- Playback composition: overlaps between chunks are trimmed against the audio actually
  inserted (`TrackPlacement`), so a chunk that is missing, unreadable, shorter than the
  manifest says, whose track or time range cannot be loaded, or that AVFoundation
  refuses leaves only its own time silent and never shortens the next chunk.
- Echo-free playback (`SessionAudioComposition.makePlayback`, `ReviewEchoMute`,
  `ReviewMicVolume`): when the call's current echo analysis found echo (§5.11,
  `EchoMaskStore.current` with verdict `echo`), the player item gets an audio mix that plays
  the microphone track at full volume in `AcousticEchoMask.localSpeechIntervals()` (local
  stretches with at least 3 frames clearly above the predicted echo, §5.11 *Playback*) and at 0
  elsewhere, with 25 ms linear ramps (a fade in ends where an interval starts, inside its
  lead padding; a fade out starts where it ends; intervals closer than two ramps are
  joined). The echo is muted only where the system track plays: a call whose system chunks
  are all unplayable has no system track and plays the microphone as recorded, and where
  the system track has no audio the microphone is kept at full volume (the mask matches
  the manifest, not what could be played). The system track and any other track play as
  recorded. No analysis, one out of
  date, damaged, or written by a newer Voice is Local, and every other verdict (`noEcho`
  for headphones, `noSystemAudio`, `tooLong`) play the microphone as recorded. When the
  labels the window adopts come with another echo mask (`echoMaskIdentity`: a relabel in
  the window, a reread, `session echo-analyze`), and when the labels are reread after the
  window was elsewhere, the volume is read again, and a changed one replaces the item's
  mix in place, so playing goes on where it is; a read that a newer one or a rebuilt
  playback overtook is dropped. Ramps are
  added last first: AVFoundation keeps them sorted, and in time order 12,000 ramps took
  13 s to add, last first 13 ms (debug build).

**Reviews and maintenance** (`ReviewMaintenance`, one rule for every command on a meeting
whose review is open or still opening):

- A meeting with a review open, opening, or still saving is under review
  (`MeetingController.sessionsUnderReview`): the automatic relabel skips it, as it skips a
  meeting in `sessionsInUse`. A review does not hold `sessionsInUse` itself, so Meetings
  commands still run and the review follows them as below; a relabel started from the
  review holds it ("Labelling speakers (Review)…") while it runs.
- A command's run holds the meeting in `sessionsInUse` (`beginUsing`) before the review is
  let go of, and ends that use (`endUsing`, which derives the naming offer again) when it
  ends, however it ends.
- The review reads, shows, and exports the recognition result only when
  `VoiceProfileService.recognitionAllowed` says so, as the CLI and the Meetings window do.
- When a command starts, a review still opening is waited for. Delete Meeting closes the
  review (its changes saved) before the meeting moves; a review that finishes opening
  during the deletion is closed unseen. Recover, Label Speakers, Delete Audio, and the
  automatic relabel make the review read-only with a banner ("Holos is recovering this
  meeting. The review is read-only until it finishes."): `ReviewSession.pause` returns
  once every earlier change is saved and the transcript files are written, playback stops,
  and the audio composition is dropped. A review that opens during the command opens
  read-only; one that opened on files a command changed meanwhile rereads them.
- When the command ends, however it ends, the review rereads the transcript, labels, and
  people (`ReviewSession.resume`), rebuilds playback from the manifest as it now is (off
  when the audio is gone), and is editable again. A playback build that failed can be
  retried: the window rebuilds it when it becomes key again.
- Clean Up removes only `derived/` renders, which the review never reads: no effect.
- Closing: when the transcript files cannot be rewritten (`exportProblem`), the labels
  stay saved, an alert says so (not while quitting or deleting), the meeting is marked in
  `PendingExports` (UserDefaults), Meetings says the files are older than the labels, and
  the next review of the meeting rewrites them. Quitting waits at most 10 s for reviews
  to close (`waitAtMost`) and never awaits a save that runs longer.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `nextUncertainWrapsInTimeOrder` | uncertain T3, T9 | after T9 → T3 |
| `searchIsCaseInsensitive` | "BUDGET" | turns containing "budget" |
| `sampleClipsPickLongestNonOverlapped` | turns 10 s, 6 s (overlap), 3 s, 8 s | clips from the 10 s, 8 s, 3 s turns; lengths 4, 4, 3 |
| `previewsShowTwoLongestTurns` | turns of 3 lengths | the two longest, each ≤ 60 characters |
| `assignSelectionIsOneBatch` | assign T4, T5, T6 | one `reassignTurns` line |
| `projectionUpdatesBeforeWriteCompletes` | editor delayed 0.5 s (test seam) | `projection` shows the change at once; the snapshot updates later |
| `refusedEditReloads` | head changed underneath | `apply` throws; snapshot reloaded to the new head |
| `undoIsLastInFirstOut` | two edits, two undos | reverts in reverse order |
| `confirmAllIsOneUndo` | 3 suggestions; confirm all; undo | all three links reverted |
| `exportsRegenerateAfterDelayAndOnClose` | edit with 0.1 s delay; then edit and close | exports updated after the delay; close flushes |
| `compositionPlacesChunksAtSessionTimes` | chunks 0–30, 30–60, 65–95 (mic) | composition segments at those times; total 95 s |
| `compositionTrimsOverlappingChunks` | legacy chunks 0–30 and 29.8–60 | second inserted from 30.0; no overlap; total 60 s |
| `maintenancePauseSavesEarlierChangesAndRefusesNewOnes` | edit saving; pause | refused at once; pause returns after the save and the exports |
| `resumeRereadsTranscriptAndLabels` | pause; new transcript and head; resume | new run, new transcript's words, editable |
| `exportsNotWrittenAtCloseStayPendingForTheNextReview` | exports blocked at close | `exportsPending` after close; the next review rewrites them |
| `clearingAnAutomaticNameRejectsItsPerson` | empty name on "Jim (auto)" | rename nil + rejectProfile Jim, one batch |
| `waitAtMostReturnsWithoutAwaitingWorkThatHangs` | work that never ends, 0.1 s | returns false; work not cancelled |
| `failedUndoKeepsTheChangeUndoable` | two edits; undo with the journal read-only | throws; newest still shown and undone next |
| `failedUndoOfATwoBatchChangeCanBeFinished` | assign to a person; second revert refused | link reverted; next undo removes the speaker |
| `failedUndoOfASavingChangeShowsItAgain` | undo while saving; its revert refused | change shown again and undoable |
| `savedChangeThatCannotBeRereadMakesTheReviewReadOnly` | line saved; rereads fail | change shown; read-only until a reread works; then undoable |
| `reloadsRereadPeopleBeforeTheLabels` | person renamed; reload; then an edit | automatic name follows the new name each time |
| `compositionPlanTrimsOnlyAgainstAudioInserted` | missing, 5 s, or 15 s of a 0–30 chunk; 10–40 next | next trimmed by nothing, nothing, 5 s |
| `compositionDoesNotTrimAfterAMissingOrShortChunk` | files as above | next chunk placed whole at 10 s |
| `compositionLeavesUnreadableChunksSilent` | garbage and truncated chunks between good ones | only their time silent |
| `trackerReportsEveryPlaybackStateTransition` | loading → off → other reason → ready | every change reported |
| `ReviewParagraphsTests` | synthetic turns | rows by speaker, 3 s gap, unknown by track, split parts and breaks; Split Turn on a row: split or break; joining a row to the one before (its speaker, joins past breaks, splits and the gap; a join replaces a break and a break a join; kept and dropped as breaks are; clearing joins keeps the breaks); the word playing |
| `reviewAssigningAParagraphMovesEveryTurnOfItAndUndoRestoresIt` | assign a two-turn row; undo | one `reassignTurns` of both turns; rows join; undo restores turns and rows |
| `reviewSplittingInsideAParagraphStartsOneThatUndoJoinsAgain` | split inside a row's first turn; undo | the second part starts a row with the next turn; undo joins them |
| `TurnListViewTests` (HolosAppTests) | the list laid out offscreen | rows joined, word click, fixes and VoiceOver, selection, pop-up and hint, tint through a pause; no warning column: the hint first in the pop-up ("Jim (suggested)") gives its turn alone, uncertain and overlap rows only in VoiceOver and Next Uncertain, the text right after the pop-up |
| `TranscriptWordEditTests` | hand-built transcripts | one word, more and fewer words, deletion into a neighbour, a fixed transcript's base edited too (word fixes made again give the same words), a fix taken whole, untimed words, refusals, exact restore, shown words to stored indices with hidden echo, an edited word never hidden as echo; a segment's every word deleted and restored (both layers, word fixes made again, a damaged record, an older build's read) |
| `TranscriptEditLearningTests` (HolosCoreTests) | heard/meant pairs | corrections learned with a neighbour; deletions, punctuation, and case changes skipped unless a proper noun; terms offered; often-heard-as |
| `ReviewWordEditTests` | fixture sessions | edit, learn, speaker edits before and after, undo in order and exactly; edit and deletion inside a paragraph; refusals across turns, segments, hidden words; word fixes made again keep an edit |
| `ReviewSegmentDeletionTests` | fixture sessions | a turn's first, middle, last, and only segment deleted whole: turn text, speakers, text/Markdown/JSON exports, the run's record and emptied turn; undo; Restore from the nearest turn and its undo; a reread plan keeps the emptied turn; an owed head repaired from the recorded move; nothing learned; a live correction refused; no "What you typed: “”"; every turn's times as they were after a deletion and its undo or Restore; every turn deleted, then restored from the full list |
| `TurnListWordEditTests` (HolosAppTests) | the list laid out offscreen | word clicks play or edit by mode; Return, ⌥Return, Esc, Tab, ⇧Tab; selection kept in one turn; only Esc drops what was typed (mode off, a search filtering the row away, words gone, read-only: queued as an edit); VoiceOver "Edit"; Revert offered per segment (`revertRefusal`); the field follows its words |
| `ReviewWindowJoinTests` (HolosAppTests) | a review window over a meeting written to a temporary folder (no audio), never shown | ⌘Z in the reopened field undoes the join's speaker; the field reopens where its word is after a word edit saved first; a join made while its split saves survives the saved ID; a named row of two tracks joined to the unknown speaker stays whole; joins in a row, and with another assignment queued first, read as one; any review Undo, a failed change (also at a close by hand), an undo saved elsewhere and a relabel drop every join; ⌘Z with typing to undo undoes the typing and keeps them; a join dropped by ⌘Z (queued or saving) opens no field; a join resolved before a relabel is refused; keys pressed while the join saves are refused (never playback's or the list's) and the field opens again as it was; ⌘Z undoing the join, or joins dropped by a refresh, stop the refusal at once |
| `ReviewKeyWindowTests` (HolosAppTests) | pure, plus a window never shown | which keys are refused while a join's field is closed (every key without ⌘, and ⌘-arrows); only the newest join reopens it |
| `TurnListJoinTests` (HolosAppTests) | the list laid out offscreen | Backspace at a row's start and forward Delete at its end join rows (another speaker's row takes the speaker before); elsewhere, selected, or typed they edit text; nothing at the meeting's edges, read-only, or outside edit mode; rows found among all grouped; the caret where the rows met; split then joined reads as before and splits again; Join With Previous Turn in the menu and VoiceOver |
| `ReviewEchoMuteTests` | local-speech intervals (edges, joins, from 0, past the end, none) | the volume schedule; a mix on the microphone track only, read back as scheduled |
| `playbackKeepsTheMicrophoneOnlyWhereItHasLocalSpeechWhenThereIsEcho` | a call with an echo mask, then `noEcho`, then other audio | a mix on the microphone track only with an echo mask; none otherwise |
| `ReviewPlayerTests` (HolosAppTests) | a playback with and without a volume; a changed volume | the item's mix follows it, replaced in place |
| `ShortInterjectionTests` (HolosSpeakersTests) | synthetic turns shaped like the rows that asked for it | a lone "an" and standalone "Yeah." hidden; words finishing the previous speaker's sentence attached; a longer unknown turn kept; a few words inside one speaker's speech attached, not across a long gap or another speaker; edited, assigned and split turns untouched; fillers by language; exports leave hidden ones out and write attached ones with the neighbour (`"interjection": "attached"`) |
| `nextUncertainSkipsHiddenInterjectionsUnlessTheyAreShown` | a fixture session with a hidden "Yeah." | skipped and not listed; listed and next once shown; never in the Markdown export |
| `choosingUnknownForAnAttachedTurnIsSavedAndUndone` | an attached turn given Unknown; undo | the edit is saved though no stored speaker changes; shown unknown; attached again after undo |
| `ReviewPanesTests` (HolosAppTests) | the panes and the list laid out offscreen | hiding the speakers pane gives the list the window's width, showing it brings it back, each change reported once; the state per meeting, capped; Show Short Interjections lists the hidden turn as its own unknown row, the attached one stays in its neighbour's row; the View menu's targetless actions reach the window's delegate (`NSWindow.supplementalTarget`); a hidden interjection playing tints no row, a pause still does; a name being typed is found through the field editor |

**Manual.** H14 and H20 in §7.

**Does not touch.** HolosSpeakers algorithms, `MeetingStartPanel.swift`, `HolosApp.swift`,
profile store, CLI, `Package.swift`, `Fakes.swift` and `SessionFixtures.swift` (PR11 owns
them in wave 5).
