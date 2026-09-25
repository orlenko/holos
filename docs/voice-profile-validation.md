# People and voice profiles: manual validation

These are manual acceptance steps on the user's Mac, not checks the automated suite performs
(docs/meeting-design.md §7.2, PR10). Record the date, the Holos build, and the result under each
check. Voiceprints are biometric data about the people in a recording: only remember the voices of
people who agreed to it, and use your own voice or willing colleagues for these checks.

Build and install as for the meeting checks ([meeting-validation.md](meeting-validation.md)); the
commands below use the bundled tool (`build/Holos.app/Contents/MacOS/holos`) or a `swift build`
one. The speaker models must be installed (`holos setup --speakers`, or Setup → Speaker labels).
Where a step says `<session>`, use the session ID or `.holos` path that `holos session list` shows.

## H15: A confirmed voice is suggested in a later meeting

1. Turn **Remember voices** on: `holos people remember on`, or check "Remember voices of people I
   name" in **People…** (menu bar). `holos people list` says `Remember voices: on`.
2. Meeting A: record a short meeting with the willing person (or import one with
   `holos session import <file>`). Once it is labelled, find their speaker with
   `holos speakers list <A> --turns`, then link it with voice learning:
   `holos speakers link <A> <speaker> new:<Name> --learn-voice`.
   The command prints `Learned <Name>'s voice from this meeting (m:ss of speech).` (with a note when it
   is short, under 20 s). **People…** lists the person with `1 · m:ss` (or `1 · weak`).
3. Meeting B with the same person: record or import it. Once it is labelled,
   `holos speakers list <B>` shows `suggestion: Maybe <Name> (0.xx)` on their speaker. The
   suggestion is not in `exports/transcript.md`, `.txt`, or `.json`.
4. Confirm it: `holos speakers link <B> <speaker> <Name>`; the speaker is named in B's exports.
5. Forget the person: **People…** → select them → **Forget <Name>…**, or
   `holos people forget <Name> --yes`. `holos speakers list <B>` no longer shows a suggestion, and
   the meetings keep the name they were given (`holos speakers list <A>`).
6. Label meeting B again (`holos session diarize <B> --force`): no suggestion comes back.

Pass: B suggests the person ("Maybe …") without naming them automatically; nothing about the
suggestion appears in exports; after Forget the suggestion is gone, also after relabelling, and the
meetings keep their names.

Result: Pending.

## People window and storage

1. With **Remember voices** off, link a speaker to a new person without `--learn-voice`. **People…**
   lists them with "no samples"; turning the setting on or off never removes names.
2. Rename a person (**Rename…**); merge two people (**Merge Into…**); turn off "Suggest <Name> in new
   meetings" and check that a new meeting with them shows no suggestion.
3. Forget one sample (**Forget** on its row), then **Forget All Voices…**: every sample is gone,
   every person stays.
4. Uncheck **Remember voices** while samples exist: the window asks "Also forget the N saved voice
   samples and the voice data of M meetings?"; **Keep** keeps them, **Forget** removes them.
5. Storage: `ls -la ~/Library/Application\ Support/Holos/Speakers` shows the folder as `drwx------`
   and `profiles.json` as `-rw-------`; `tmutil isexcluded ~/Library/Application\ Support/Holos/Speakers`
   says it is excluded from backups.
6. `holos people export --output ~/Desktop/people.json` writes names and sample details without
   voiceprints; `--include-voiceprints` warns on stderr that the file contains biometric data.

Pass: every step behaves as described; no voiceprint is written anywhere except the people store
(and an explicit `--include-voiceprints` export).

Result: Pending.
