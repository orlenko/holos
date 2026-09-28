# Menu bar dictation: setup and validation

This is a manual acceptance guide for the second milestone. The app has been
compiled, packaged, and ad-hoc signed locally, but its interactive microphone,
global hotkey, overlay, and cross-app Accessibility behavior has not yet been
smoke-tested. Do not treat a successful build or unit-test run as proof that it
will insert reliably into your everyday apps.

## Build and set up

On macOS 27 / Apple Silicon with Swift 6.4, run:

```sh
./scripts/build-app.sh
build/VoiceIsLocal.app/Contents/MacOS/HolosApp --check
open build/VoiceIsLocal.app
```

The build creates an ad-hoc-signed accessory `build/VoiceIsLocal.app`; it does not
install or launch it, create a login item, or enable dictation. `--check` is a
noninteractive packaging/read-only permission-status check. It does not prompt,
record, install a keyboard event tap, inspect a focused field, or use the
clipboard. Launch with `open` only when ready for an interactive test.

On first launch, the Setup Assistant opens (run it again with **Run Setup Assistant…**
in Settings); its checks are under [Setup Assistant](#setup-assistant) below. Later
launches, and **Skip — Show All Settings**, open the main window on **Settings**
(**Settings…** ⌘, in the menu). Use its Permissions card to grant Microphone and
Accessibility access explicitly (Input Monitoring is not needed; its row appears only if
macOS refuses the hold-to-talk key with Accessibility on); in the Dictation card pick the
**Dictation language** (English (Canada) by default) and the hold-to-talk shortcut, and
install Apple's speech model for the language; each row updates live, and its button
opens the matching System Settings pane. A new language applies from the next dictation;
when its model is missing, dictation turns off until it is installed. The asset action
may download Apple's model. Then turn dictation on in Settings or the menu. The default user-selectable shortcut is **Right Option**;
**Control–Option–Space** is the alternate. Once enabled, hold the chosen shortcut,
wait for “Listening” in the non-activating preview, speak, then release. Releasing
during startup produces a retry message instead of a partial insertion. Esc or
“Cancel Dictation” cancels, including while finalizing.

Right Option is reserved while its shortcut is enabled. Unrelated typing while
holding it cancels dictation and may be consumed until the key is released. Use
the alternate shortcut or disable dictation if Right Option is needed for other
work. Sleep or session lock pauses dictation; re-enable it manually from the menu
after waking. There is no automatic login launch or background installation.

## Setup Assistant

None of these checks has been run yet. To see the assistant as a new user would, run
`defaults delete ca.orlenko.holos.app setupAssistantDone` with Voice is Local quit, and
remove Voice is Local from Microphone and Accessibility in System Settings; or use
**Run Setup Assistant…** in Settings, which starts at Welcome without either.

1. **Welcome**: Start goes to the next page; **Skip — Show All Settings** opens
   Settings in the main window, and the next launch does not show the assistant.
2. **Language and microphone**: Next stays off until the microphone is allowed
   (**Allow Microphone** shows macOS's prompt once; when access was turned off before,
   the button reads Open Settings). Clicking Next starts the speech model download, and
   the speaker model download when "Also set up meetings" is checked; their progress
   shows at the bottom of the following pages.
3. **Accessibility**: the row turns green on its own within a second of switching Voice
   is Local on, with no reopen. Continue Without is offered while it is off.
4. **Permissions that need a reopen**: Open Settings for Screen & System Audio
   Recording; when macOS offers Quit & Reopen, choose Later. The main button reads Skip
   until Open Settings was clicked, then Next. The page is passed over when system audio
   is already allowed (and Input Monitoring is not needed).
5. **Finish**: lists each item's real state. After Open Settings on the previous page,
   the button is **Reopen Voice is Local**: the app quits and opens again by itself, then
   shows **Setup check** once with system audio now allowed. Start a meeting recording
   first and click Reopen: the usual "A meeting is recording" question appears, and
   Cancel keeps the app running and does not reopen it later when you quit. Without a
   request the button is **Done**.
6. Dictation turns on at the end when Microphone, Accessibility and the speech model
   allow it; when the model is still downloading, it turns on once the download ends.
7. Close the window midway, quit and reopen: the assistant shows again. An existing
   install (dictation already on) does not see it after updating.

**Input Monitoring is not needed** (unverified on the target Mac until this is run):
in System Settings → Privacy & Security → Input Monitoring, switch Voice is Local off
(or remove it), quit and reopen Voice is Local, then dictate: the hold-to-talk key
should still work, and Settings should show no Input Monitoring row. If instead the menu
says macOS refused the hold-to-talk shortcut although Accessibility is on, Settings shows
an Input Monitoring row; switch it on there, quit and reopen, and note it here.

## Main window and history

None of these checks has been run yet; nothing of the main window has been seen on
screen. Rebuild and relaunch with `./scripts/restart-app.sh` (only when no meeting is
recording), then:

1. **Open with ⌘0**: open the menu bar menu and choose **Open Voice is Local** (⌘0): one
   window, about 1280 × 800 the first time, with the sidebar (Dictation: History,
   Corrections; Meetings: Meetings, People; Listen: Reading; Settings) and the status card
   at its bottom ("Dictation ready" and the current message; "Dictation paused during
   meeting recording" while a meeting records). Resize it, close it, reopen it: same size
   and place. The app shows in the Dock and ⌘-Tab while it is open. Check light and dark
   mode.
2. **⌘1–⌘5 and ⌘,**: with the window key, each switches section (History, Corrections,
   Meetings, People, Reading, Settings), and the menu bar shows Voice is Local, Edit, Go,
   and Window menus with those items (Settings… under Voice is Local, Find… under Edit). With the window closed and another Voice is Local window key (the
   Setup Assistant, Review), ⌘1 opens it on History.
3. **⌘F** in History focuses the search field; typing filters by text and app; Escape
   in the field clears it. Tab and ⇧Tab reach the sidebar, the list, and the detail's
   buttons; ↑↓ move in the list; Return moves to the text; ⌫ asks before deleting.
   With Full Keyboard Access on, every button and pop-up is reachable. VoiceOver reads
   each row (app, time, badge, text) and the status card.
4. **A dictation is recorded**: dictate a sentence with a filler ("um") into TextEdit,
   one into Terminal, and one into a field that cannot be written (a web page's
   read-only area, or switch apps while speaking). History shows each under Today with
   the time, the app (TextEdit, Terminal, …), a two-line preview, and **Fixed** (filler
   removed or a correction applied) or **Not inserted**. The detail shows the full text,
   **As heard, before fixes** with the changed words marked, Result ("Inserted into
   TextEdit", "Typed into Terminal", "Not inserted — … Use Copy."), Language, Fixes, and
   Length. With Apple Intelligence's fix on, Fixes counts the words it changed.
5. **Copy only on request**: after each dictation, the clipboard still holds what it
   held before. **Copy** (or ⌘C with the list focused) and **Copy As Heard** (⇧⌘C) put
   that text there; nothing else does. **Correct…** (⌘E) opens Corrections with that
   dictation's text.
6. **Password fields are not recorded**: try to dictate into a password field (and with
   Terminal's Secure Keyboard Entry on); History gets no entry.
7. **Retention Off stops recording**: Settings › History and privacy › Keep dictations
   → Off; when dictations are kept it asks whether to clear them (try Keep Them). Dictate:
   no new entry, and History says it is off. Set it back to 30 days.
8. **Clear History**: **Clear History…** (History's footer or Settings) asks first, then
   empties the list; `voiceislocal history list` prints "No dictations in the history."
   `ls -l ~/Library/Application\ Support/Holos/History` shows `dictations.jsonl` as
   `-rw-------`.
9. **Menu**: the menu bar menu shows the status line, the dictation toggle, Copy Result /
   Copy Original / Discard Result only while a result is kept, Correct Last Dictation…
   (opens Corrections with the last dictation), the meeting lines, Open Voice is Local
   ⌘0, History, Meetings, Settings… ⌘,, About, and Quit. The language and shortcut are
   changed in Settings, not the menu.
10. **Hosted sections**: Meetings (Review…, Recover…, Quick Look of a transcript, Save
    Transcript As… as a sheet, Delete Meeting… with ⌫) and People (Rename…, Merge,
    Forget…) behave as their windows did. While a meeting records or is processed (by
    the app or `voiceislocal` in Terminal), Delete Meeting… is disabled and ⌫ on it only
    beeps, with no confirmation.

## Dictation audio and Run Again

Not run yet. With History on (30 days) and Settings › History and privacy › **Keep the
audio of dictations (for Run Again)** on (the default):

1. **Audio is kept**: dictate a sentence with a word the recognizer gets wrong (for
   example "Ubuntu") into TextEdit. In History, the dictation's detail shows **Play**
   with "0:00 / 0:04" (its length) and **Run Again**. `ls -l ~/Library/Application\
   Support/Holos/History/audio` shows `<id>.m4a` as `-rw-------` (the ID is the one
   `voiceislocal history list --json` prints) and no `.partial.m4a` left. Settings shows
   "Dictation audio uses … on this Mac".
2. **Play it**: **Play** plays what you said, from the start (the position counts up;
   the button becomes **Pause**). With the list focused, Space pauses and plays again.
   Selecting another dictation, or another section, stops it.
3. **Run Again after a correction**: in Corrections, teach the misheard phrase → the
   right word. Back in History, select the dictation and press ⌘R (or **Run Again**).
   After a few seconds the Run Again box shows Heard then / Heard now, Written then /
   Written now with the differing words marked, the steps ("Corrections: “a boon to” →
   “Ubuntu”"; Apple Intelligence off or its change), and "Different: Corrections".
   Nothing was typed into the frontmost app and the clipboard still holds what it held.
   **Copy New Result** copies the new text; **Update History…** asks, then the
   dictation's text in History becomes the new text (its audio stays).
4. **Terminal**: `voiceislocal history rerun latest` prints the same comparison;
   `voiceislocal history rerun latest --json --no-ai-fix` prints it as JSON without the
   fix; `voiceislocal history rerun --all --since 1d --json` lists each dictation of the
   last day with `changed` and `changedBy`, and dictations without audio as skipped.
   (The CLI needs the language's speech model installed for itself: if it says the
   speech assets are missing, run `voiceislocal setup --locale <language>` first.)
5. **Off stops keeping audio**: untick **Keep the audio of dictations**; it asks whether
   to also delete the audio already kept; choose **Keep It**. Dictate: the new dictation
   has "No audio was kept for this dictation." and no new file appears in `audio/`. Tick
   it again, untick it and choose **Delete Audio**: `audio/` is empty, the older
   dictations say no audio was kept, and their text stays. Tick it again.
6. **Cancelled and refused dictations leave no audio**: press Escape while dictating,
   and try a password field: no file appears in `audio/`.
7. **Delete and Clear remove audio**: Delete one dictation (⌫): its `.m4a` is gone.
   **Clear History…**: `audio/` is empty. `voiceislocal history clear --yes` also
   removes the audio.

## Result and privacy behavior

The app previews the current recognition hypothesis. Words the recognizer has
finalized are written into the target while you are still speaking; volatile words
stay in the preview until they settle, and releasing the shortcut writes whatever
the final transcript adds. Text is only ever appended, never rewritten. Surrounding
whitespace/newlines are trimmed and no Return or newline is ever written.

For a regular text field, each chunk is a direct Accessibility `AXSelectedText`
replacement, attempted only when the focused field is a supported writable,
non-secure plain text field and the app, field, selection, text length, and nearby
text still match the snapshot taken at key-down or after the previous chunk. Each
write is read back. For a known terminal app (Terminal, iTerm2, Ghostty, WezTerm,
kitty, Alacritty, Warp), which has no writable text field, chunks are typed as
keystrokes posted only to the terminal that was frontmost at key-down, and only
while the terminal session focused at key-down still has focus: before each chunk
(and every 16 characters within one) Voice is Local checks that the terminal is
still frontmost and that its focused window and focused element, as reported to
Accessibility, are the ones captured at key-down. Terminal and iTerm2 are expected to
report a text area per session, so switching tabs, panes or windows stops typing and
keeps the rest for Copy Result. A terminal that reports only its focused window is
tracked by window, so a switch of pane inside one window is not detected there; one
that reports neither is tracked only by staying frontmost. Typed text cannot be read
back. A focused editable field that
has no direct Accessibility write, such as a web rich-text editor, is typed into the
same way, but only while that exact element keeps focus. Chromium browsers and
Electron apps are asked to expose accessibility (`AXManualAccessibility`) when they
become active, since they otherwise report no focused element. A password/secure
field or Secure Keyboard Entry is refused.

Hesitation sounds ("um", "uh", "ah", "erm", "hmm") and the commas around them are
removed before corrections are applied, unless **Remove filler words** is turned
off in Settings. "mm", "hm", and "er" are kept because they collide with
units and abbreviations. French dictation removes "euh", "heu", "hum", "hmm", and
"bah" instead, and keeps words such as "ah", "ben", "bon", "hein", "genre", and
"tsé", which carry meaning. Other languages keep every word.

The first refusal stops writing for the rest of that utterance. Text already
written stays in place, and the unwritten remainder is kept for **Copy Result** or
**Discard Result** in the menu. Voice is Local never puts dictated text on the
clipboard by itself (dictation can be sensitive, even a password) and never pastes;
only choosing Copy Result or Copy Original writes the clipboard. The same applies to committed words
left unwritten when an utterance fails. If the
recognizer's final transcript no longer starts with what was already written,
nothing more is written and Copy Result holds the full transcript. Direct insertion
support is target-app dependent and has not been broadly established. If insertion
is reported as unverified, inspect the field before copying to avoid duplicating
text.

The maximum utterance is 120 seconds; finalization after listening has a
30-second limit. When the maximum duration forces a stop, anything already
streamed stays and the remainder is kept for Copy Result rather than being auto-inserted. The overlay hides eight seconds after a result, but its text remains
in app memory and the menu's Copy/Discard actions for up to ten minutes (unless
replaced, discarded, or the app quits). Only a later dictation that produces a
result replaces it: recognized text, or text left unwritten. A press that is
cancelled, released before Listening, or recognizes nothing leaves the earlier
result, its menu items and its ten-minute expiry as they were. The system clipboard is overwritten only when
**Copy Result** or **Copy Original** is chosen, or **Copy** / **Copy As Heard** / **Copy New Result** in History. Dictation audio
is kept only with its History record (unless Settings turns it off; [Dictation audio and Run Again](#dictation-audio-and-run-again)); the text of finished dictations is kept in History on this Mac for 30 days
unless Settings says otherwise ([Main window and history](#main-window-and-history)).

## Corrections

**Correct Last Dictation…** in the menu opens the main window's Corrections section with
the last transcript as Voice is Local wrote it (History's **Correct…** opens it with the
chosen dictation instead).
With **Fix misheard words with Apple Intelligence** on, that is the fixed text, so
learning picks up only your own edits; **Copy Original (As Heard)** still has the
text as recognized.
Fix misheard words there and choose **Learn Corrections**; Voice is Local compares the two
versions and keeps short word swaps (up to a few words; insertions, deletions, and
longer rewrites are ignored). A misheard single word that is itself a dictionary
word is kept with a neighbouring word, so "bull" → "pull" becomes "bull request" →
"pull request" instead of rewriting every "bull". Pairs can also be added or removed
by hand in the same section. They are stored in
`~/Library/Application Support/Holos/corrections.json`, one list shared by every
dictation language.

**Fix misheard words with Apple Intelligence** is offered for English and French
dictation; other languages show it as unavailable until they have been tried.
The model sees a learned pair only when its whole heard phrase (or, for words the
spell checker does not know, the same words misheard a little differently) is in the
chunk. A fix that replaces a real word by anything but a listed homophone, or a word
the spell checker does not know by one that does not sound like it, is refused,
unless it turns that heard phrase into the meant one. Check with pairs such as "Onobunto" → "on Ubuntu" and "a Bundo" →
"ubuntu": "The build runs Onobunto" becomes "The build runs on Ubuntu", while "Let's
develop it on a Windows machine first" and "That's the point" stay as said.

Corrections are applied, whole-word and case-insensitively, to the preview and to
every streamed and final chunk. While streaming, trailing words that could start a
multi-word phrase are held back until the next words arrive. The distinctive words
of the corrected phrases (no function words, once each ignoring case) are also passed
to the recognizer as contextual strings, which is best effort.
Learning does not change text already inserted into other apps.

Insertion decisions (target kind, chunk lengths, outcomes, and why streaming
stopped) are logged without transcript text:

```sh
/usr/bin/log stream --style compact --predicate 'subsystem == "ca.orlenko.holos.app"'
```

## Manual acceptance matrix

Use disposable text and a short utterance; avoid sensitive content while checking
permissions and targets. Record the app, field type, expected behavior, actual
behavior, and permission owner for each row.

| Scenario | Expected check |
| --- | --- |
| TextEdit plain text, empty caret and selected text | One insertion/replacement, with no extra newline or duplicate text. |
| Browser text field and rich editor (e.g. ChatGPT in Chrome) | Phrases are typed as you pause while that field keeps focus; moving focus stops typing and keeps the rest for Copy Result. |
| Native field without direct Accessibility writes | Typed into while it keeps focus; a field that fails a safety check (large selection, unreadable range) is not typed into and its text is kept for Copy Result. |
| Terminal input (shell prompt and a TUI such as Claude Code) | Phrases are typed as you pause; never a Return; Secure Keyboard Entry refuses. Switching tab, split pane or window while speaking stops typing; nothing lands in the new session, and the rest is kept for Copy Result. Check Terminal and iTerm2 (tabs and split panes), and one of Ghostty, WezTerm, kitty, Alacritty or Warp (the log line "focus tracked by session/window/app" shows which level that terminal supports). |
| Accidental press after a dictation that left text for Copy Result | Tap the shortcut and release before Listening, press and Esc, or hold without speaking: Copy Result, Copy Original and Discard still offer the earlier text, which still expires ten minutes after its own dictation. A later dictation that recognizes words replaces it. |
| Learn "bull request" → "pull request", then dictate it | Corrected in preview and in the field; "bull market" unchanged. |
| Long utterance with pauses in TextEdit | Finalized phrases appear while speaking, the tail on release, no duplicates or missing spaces. |
| Password or secure field | Refuse dictation/insertion; no text lands in the field. |
| Switch app, field, caret, selection, or nearby text during speech | Writing stops; earlier chunks stay, the remainder is kept for Copy. |
| Release before “Listening” | Stop startup cleanly, no late insertion, then allow a fresh attempt. |
| Esc during listening and again during finalizing | Stop and suppress late results/insertion; already-streamed text stays. |
| Rapid repeat presses and unrelated typing while holding | One utterance at a time; no stuck mic or duplicate insertion. |
| Missing/denied permissions or assets | Clear setup status; no implicit asset download or microphone prompt on shortcut press. |
| Maximum duration and delayed finalization | Stop at 120 seconds; the unwritten part of a forced result is kept for Copy Result, not inserted, and post-listening finalization does not hang past 30 seconds. |
| Unwritable target after a streamed prefix | The clipboard is unchanged; Copy Result holds only the unwritten tail, with its leading space, so pasting it after the prefix gives correctly spaced text. |
| Sleep/lock and wake | Capture stops; shortcut stays paused until manually re-enabled. |

Also test the clipboard: after text Voice is Local could not write, the clipboard should
still hold whatever was there before; **Copy Result** should then copy the retained
text; Discard should remove the retained result. After a
completed utterance, check that the overlay hides after about eight seconds and
the retained result expires after about ten minutes. If the app reports an
unverified Accessibility write, inspect the target before using Copy.

The CLI workflows are unchanged. For separate microphone/system-audio recording
and archive checks, use the [live-recording checklist](hardware-validation.md).
