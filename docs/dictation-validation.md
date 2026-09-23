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
build/Holos.app/Contents/MacOS/HolosApp --check
open build/Holos.app
```

The build creates an ad-hoc-signed accessory `build/Holos.app`; it does not
install or launch it, create a login item, or enable dictation. `--check` is a
noninteractive packaging/read-only permission-status check. It does not prompt,
record, install a keyboard event tap, inspect a focused field, or use the
clipboard. Launch with `open` only when ready for an interactive test.

On first launch, the Holos Setup window opens (reopen it with **Setup…** in the
menu). Use it to grant Microphone, Accessibility, and Input Monitoring access
explicitly and install Apple's English (`en-CA`) Speech assets; each row updates
live, and its button opens the matching System Settings pane. The asset action may
download Apple's model. Then enable dictation from the window or the menu. The default user-selectable shortcut is **Right Option**;
**Control–Option–Space** is the alternate. Once enabled, hold the chosen shortcut,
wait for “Listening” in the non-activating preview, speak, then release. Releasing
during startup produces a retry message instead of a partial insertion. Esc or
“Cancel Dictation” cancels, including while finalizing.

Right Option is reserved while its shortcut is enabled. Unrelated typing while
holding it cancels dictation and may be consumed until the key is released. Use
the alternate shortcut or disable dictation if Right Option is needed for other
work. Sleep or session lock pauses dictation; re-enable it manually from the menu
after waking. There is no automatic login launch or background installation.

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
while it is still frontmost; typed text cannot be read back, and switching tabs or
panes inside the terminal while speaking redirects it. A focused editable field that
has no direct Accessibility write, such as a web rich-text editor, is typed into the
same way, but only while that exact element keeps focus. Chromium browsers and
Electron apps are asked to expose accessibility (`AXManualAccessibility`) when they
become active, since they otherwise report no focused element. A password/secure
field or Secure Keyboard Entry is refused.

Hesitation sounds ("um", "uh", "ah", "erm", "hmm") and the commas around them are
removed before corrections are applied, unless **Remove filler words** is turned
off in the Setup window. "mm", "hm", and "er" are kept because they collide with
units and abbreviations.

The first refusal stops writing for the rest of that utterance. Text already
written stays in place, and the unwritten remainder is copied to the clipboard right
away (the status says to press ⌘V) and also kept for **Copy Result** or **Discard
Result**; the app never pastes on its own. The same applies to committed words
left unwritten when an utterance fails. If the
recognizer's final transcript no longer starts with what was already written,
nothing more is written and Copy Result holds the full transcript. Direct insertion
support is target-app dependent and has not been broadly established. If insertion
is reported as unverified, inspect the field before copying to avoid duplicating
text.

The maximum utterance is 120 seconds; finalization after listening has a
30-second limit. When the maximum duration forces a stop, anything already
streamed stays and the remainder goes to the clipboard rather than being auto-inserted. The overlay hides eight seconds after a result, but its text remains
in app memory and the menu's Copy/Discard actions for up to ten minutes (unless
replaced, discarded, or the app quits). The system clipboard is overwritten when
text could not be written or when **Copy Result** is chosen. No raw dictation audio
is saved.

## Corrections

**Correct Last Dictation…** in the menu opens the last transcript as Holos wrote it.
Fix misheard words there and choose **Learn Corrections**; Holos compares the two
versions and keeps short word swaps (up to a few words; insertions, deletions, and
longer rewrites are ignored). A misheard single word that is itself a dictionary
word is kept with a neighbouring word, so "bull" → "pull" becomes "bull request" →
"pull request" instead of rewriting every "bull". Pairs can also be added or removed
by hand in the same window. They are stored in
`~/Library/Application Support/Holos/corrections.json`.

Corrections are applied, whole-word and case-insensitively, to the preview and to
every streamed and final chunk. While streaming, trailing words that could start a
multi-word phrase are held back until the next words arrive. The corrected phrases
are also passed to the recognizer as contextual strings, which is best effort.
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
| Browser text field and editor text area | Insert only if direct writable Accessibility text is supported; otherwise preserve Copy. |
| Terminal input (shell prompt and a TUI such as Claude Code) | Phrases are typed as you pause; never a Return; Secure Keyboard Entry refuses. |
| Learn "bull request" → "pull request", then dictate it | Corrected in preview and in the field; "bull market" unchanged. |
| Long utterance with pauses in TextEdit | Finalized phrases appear while speaking, the tail on release, no duplicates or missing spaces. |
| Password or secure field | Refuse dictation/insertion; no text lands in the field. |
| Switch app, field, caret, selection, or nearby text during speech | Writing stops; earlier chunks stay, the remainder is kept for Copy. |
| Release before “Listening” | Stop startup cleanly, no late insertion, then allow a fresh attempt. |
| Esc during listening and again during finalizing | Stop and suppress late results/insertion; already-streamed text stays. |
| Rapid repeat presses and unrelated typing while holding | One utterance at a time; no stuck mic or duplicate insertion. |
| Missing/denied permissions or assets | Clear setup status; no implicit asset download or microphone prompt on shortcut press. |
| Maximum duration and delayed finalization | Stop at 120 seconds; any forced result requires Copy, and post-listening finalization does not hang past 30 seconds. |
| Sleep/lock and wake | Capture stops; shortcut stays paused until manually re-enabled. |

Also test explicit Copy and Discard: Copy should write the transcript to the
clipboard only when selected; Discard should remove the retained result. After a
completed utterance, check that the overlay hides after about eight seconds and
the retained result expires after about ten minutes. If the app reports an
unverified Accessibility write, inspect the target before using Copy.

The CLI workflows are unchanged. For separate microphone/system-audio recording
and archive checks, use the [live-recording checklist](hardware-validation.md).
