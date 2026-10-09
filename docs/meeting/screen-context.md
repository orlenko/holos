# Screen context

The optional screen context of a meeting.

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](../meeting-design.md) lists the file each is in.

### 4.15 Optional screen context

*History.* PR #71 captured one window the user picked from a list in each meeting's start
panel. After trying it, the user (2026-10-03): the window-only design "does not work well
in practice. Full screen is the practical way - we are doing it to help with the
dictation, not to steal data", and the per-meeting window list "is impractical. Full
screen recording is the real deal". Nothing leaves the Mac: there is no online model.
The capture is now of the whole display; the window picker is gone. It began with the
main display only; the user often has the call or the slides on a second monitor, so every
display connected when the capture starts is now captured (option A, "all displays",
approved 2026-10-06). The first version of #101 also followed displays plugged in or
out mid-meeting; review kept finding races in that state machine, so the owner split it
off (branch `meetings/screen-hotplug-wip`): hot-plug is a possible follow-up.

*Setting and start panel.* Settings › Meetings has one checkbox, "Capture the screen
during meetings (slides, shared screens) to improve transcripts" (UserDefaults
`meetingScreenCapture`), with a caption: everything stays on this Mac, OCR runs on this
Mac after the recording, images and text are deleted with the meeting audio, Voice is
Local's own windows are left out (notifications are not). It is off for new installs,
since it needs Screen & System Audio Recording permission; a user who had the old
window offer on (`meetingScreenCaptureDefault`) gets it on, and the old key is removed
once the setting is saved (`MeetingScreenPreference`). The start panel's Screen row is
one checkbox, "Capture screen", checked as Settings says, for this meeting only; the
last meeting's choice is not remembered. Without the permission the box is unchecked
and dimmed and says what is missing; Start is never blocked by it. The app passes
`--screen display` (every display) to the recorder; `voiceislocal record start --screen
display|main|off` (default off) is the CLI form, where `main` is the main display alone (what
`display` meant before all displays were captured). A saved `screenWindow` from PR #71
decodes as no capture. The Settings caption says "every connected display", the start panel's
note "every connected display": a display plugged in mid-meeting is captured once the
capture restarts in that meeting, so the text does not promise it is left out.

*What is captured.* One ScreenCaptureKit stream per display, each with a display filter
`excludingApplications` Voice is Local itself: `ca.orlenko.holos.app`,
`ca.orlenko.holos.cli`, the current process, and the current bundle identifier
(`ScreenCapturePlan.excluded`, applied to every display's filter), so the live transcript,
Review, and the menu are never read back into the meeting's context, whichever display
they are on. App exclusion covers windows opened later. A display that mirrors another
(`CGDisplayMirrorsDisplay`) is left out, since its snapshots would repeat. With
`--screen main` there is one stream, on the display that is main when the capture starts
(`CGMainDisplayID`, the one with the menu bar; the first listed display if the main one
is missing); it does not follow a later change of main display within that capture, but a
restart of the capture (pause, sleep, an audio device change) takes the display that is main then. If the app is not running (a CLI-only
recording), there is nothing of it to exclude. Desktop notifications and everything
else on the displays are captured. Permission must already be granted; capture failures
are optional-evidence failures and never invalidate saved audio.

*Displays.* ScreenCaptureKit is asked once, when the capture starts, which displays
there are (`SCShareableContent`, mirrors left out); each gets one stream for the whole
capture. Every display has its own retained frame and pending change
(`ScreenFrameReceiver`), so one display's video never settles or breaks another's
slide; all of them write one timeline, kept in start order, in `screen/context.json`.
Each keyframe records its display (`ScreenDisplay`): the `CGDirectDisplayID`, a number
for the meeting, and whether it was the main display when its stream began. Displays
are numbered by arrangement (left to right, then top to bottom;
`ScreenDisplayNumbering`); a display the meeting's saved keyframes already name keeps
its number when the recorder starts a new capture epoch (resuming after a pause or
sleep, or after an audio device change), which asks again, and one new by then takes the
next number. A display whose stream ends (unplugged or broken; the capture does not tell
them apart) is not captured again in that epoch: its last keyframe's interval already
ends at its last observed sample and a change that had not settled is dropped, so
nothing claims it was seen afterwards. A display plugged in during the meeting is not
captured until the next capture epoch (the displays are chosen again whenever the
capture restarts: resuming after a pause or sleep, an audio device change) or the next
meeting; the README and Settings text say so rather than promising it stays out. Following displays mid-epoch
(polling `CGGetActiveDisplayList`, restarting streams) is a possible follow-up.

The capture keeps four invariants (`MeetingScreenCapture`'s documentation): the set of
streams is decided once, at the start, and afterwards streams only end (an error, a cap,
`stop()`); every asynchronous step of a stream (its start beginning and returning, an
error callback, a sample, its stop) is checked against the stream's identity (object or
token) and phase, so an ended stream is never started or registered again and nothing it
does reaches the receiver; the capture fails ("captureFailed", as with one display) when
no stream could be started at all (the display query failed, no stream could be made,
or every platform start failed) or when the last stream still starting or running ends,
by an error or a cap (a cap can remove the last stream when another display failed while
the capping keyframe was being saved), all decided in one place, keeping an outcome the
receiver already recorded (the storage limit, a storage failure); and `stop()` is
final. Each stream is one object
(`ScreenDisplayStream`) holding its control, its output (ScreenCaptureKit holds a
stream's output and delegate weakly, so the capture keeps it for as long as the stream
may run), its token and its phase. Each stream starts in its own task, registered before
its platform start returns, so one slow or hung start holds up no other display, and a
meeting stopped (or a display capped or broken) during it stops that stream at once; a
late start return is stopped again, and frames it still delivers are fenced. Stops are
requested without waiting, all at once when the meeting stops, so one stalled platform
stop never leaves another stream running.

*Every display unplugged.* Unplugging displays is not told apart from a broken stream:
when the last remaining stream ends with an error (the lid closed on a laptop with no
external display, or every external display unplugged with the lid closed), the capture
fails with "captureFailed" ("Screen capture unavailable; audio continues"), exactly as a
single-display capture does when its stream ends. Audio goes on, and the next capture
epoch (resuming after the sleep that usually follows) or the next meeting asks for the
displays again. A single-display meeting behaves as before all displays were captured.

One serial utility queue, shared by every display's stream, samples each display at
most 0.5 fps, with no cursor or audio. Each stream delivers its display's pixels
scaled so neither side exceeds 2560 (`ScreenContextStore.maximumImageDimension`; 5K →
2560×1440, about point resolution, so slide text stays legible to OCR). Each sample is
copied through one software CIContext per capture, shared by the displays. A 160×90
grayscale fingerprint (drawn with high interpolation quality) has 16×9 tiles. At least 6 pixels changing by 20/255 within a tile makes it changed.
A sample becomes a keyframe when at least 10% of the tiles (15) both differ from the
last retained frame and are unchanged since the previous sample (`settledChange`): a
new slide or a finished scroll settles one sample later (or at the next idle sample,
which means nothing changed), while a video tile that keeps moving never counts, even
when it covers half the display. The keyframe starts at the previous sample only when
that sample showed the same picture (no tile differs); a picture that settled in part
but still differs elsewhere (a slide build's next bullet, or a video beside the slide)
starts at its own sample. A change that never settles (shown under two seconds, or still moving
at stop) is dropped. The first frame, and the first after a gap, is kept at once. This
can miss sparse edits, colour-only changes, or a slide in a window under a tenth of the
display; it is a heuristic, not a semantic slide detector. Similar samples and idle
samples extend an observed frame; suspended/blank samples break its interval. A change
that does not settle also ends the retained frame's interval at its last matching
sample: if the screen then returns to the retained picture, that is a new keyframe with
its own snapshot, so no interval claims a picture was visible while something else
was. Stop does not extend evidence into an unobserved gap.

JPEG quality is 0.65; a frame above 1 MiB is encoded again at 0.5 and 0.35, then at
half the size, before the per-frame cap can end the capture (`ScreenFrameEncoding`).

Private `screen/context.json` records UUID keyframes, observed session-time intervals,
their display, JPEG byte totals, and optional OCR lines with normalized bottom-left boxes
and confidence. Each keyframe names its display (`display`: `id`, `number`, `isMain`)
and its JPEG size (`bytes`), so each display's share of the caps is exact after a
reconnect (kept in memory) or a recorder restart (rebuilt from the keyframes; one saved
without a size counts as the meeting's average). A keyframe without a display, saved
before all displays were captured, reads as the main display. A record whose keyframes
carry either field is written with `schemaVersion` 2; this build reads 1 and 2, and a
file without a readable version is refused as damaged. A build
from before displays were named reads only 1 and refuses a version-2 file as written by
a newer version, leaving it alone (its OCR and Review report the refusal; recording and
transcripts are unaffected), rather than rewriting it without the fields it does not
know, after which every snapshot would read as the main display's. A record without
them (one saved before, even after this build recognized its text) stays at 1, so an
older build can still read it. Each display's keyframes follow one another without
overlapping; different displays' overlap in time, but every keyframe is listed in start
order (new ones are inserted by start, and a record out of order is refused as damaged),
which Review's list and the insertion rely on.
`screen/<UUID>.jpg` is owner-only. Caps are 1000 keyframes, 1 MiB per JPEG, and 256 MiB
total JPEGs, shared by all displays (`ScreenStoragePolicy`, pure): each display beyond
the first (counting only displays whose stream has delivered a sample, so a stream still
starting, or hung starting, reserves nothing) holds back a tenth of either cap (at most three tenths) for the others. Once
the meeting has used the rest (90% with two displays; 80% then 90% with three), the
busiest display stops: the one that saved the most keyframes (the most bytes when the
byte cap is the nearer), so a call's video or a scrolled document stops before the
quieter slides; on a tie the main display stays. The last display runs to the cap
itself, which ends the capture and says so ("Screen capture stopped: storage limit"),
as with one display. A display stopped for the caps is not started again in that
capture; after a recorder restart it would be stopped again at its next keyframe.
Metadata is bounded on read. Atomic no-follow reads and safe tree deletion protect
against planted links. Capture generations (one for all displays) fence old callbacks
before image creation; metadata changes use the existing speaker lock off
the main actor. Delete Audio holds that same lock for the tombstone and removal of
`screen/`, so abandoned callbacks cannot recreate deleted evidence.

Vision `.accurate` text recognition runs on a utility task **after capture stops**,
never per live frame. Language correction is disabled to avoid inventing spellings;
requested meeting languages are matched to supported Vision locales (otherwise
Vision's defaults). Completed frames persist independently and are not repeated on
resume. Each frame keeps at most 64 lines, 4000 characters total, 1000 per line.
OCR failure/cancellation preserves recording and any already recognized frames.
Recorder and recovery each process at most eight unfinished frames, waiting at most
five seconds for recognition (plus bounded metadata IO). A stuck native call may
return later, but cancellation and an OCR generation fence prevent late publication.
The next recovery resumes a batch even with no transcript, corrections, or word-list
pairs. Review's explicit Recognize Next Batch action continues under a processing
lease without blocking the recorder or a new meeting. Completed lines are not redone.

Only existing word-list heard-as questions receive nearby OCR: the candidate word's
timing (or its segment if untimed), confidence ≥0.6, deduplicated lines, at most 800
characters. OCR is quoted as untrusted data, never instructions or spoken evidence.
Unknown OCR tokens are read-only user-review candidates, not automatic vocabulary
or transcript edits. No Foundation Models or other LLM call is added during recording.
Review's Screen Text sheet selects timestamped OCR and seeks without starting
playback; when the meeting captured more than one display, each snapshot says which
("0:12–0:40 · Display 2", "Main display"; "Display 2, main" once more than one display
was main in some keyframe, as when the main display changed across a pause),
and a single-display meeting shows nothing extra. OCR and the word-list questions work
per keyframe, so they need nothing per display: OCR lines near a word come from
whichever displays were observed then. An unreadable word list disables candidate
filtering, not saved OCR display. A thumbnail timeline is an explicit follow-up.

Default tests use invented pixels, fake OCR/model responses, and temporary archives;
no permission, screen, microphone, private data, network, or installed speech models.
`HOLOS_SCREEN_BENCHMARK=1 ./scripts/test.sh --no-parallel --filter Screen` adds native
Vision measurements on a synthetic 1280×720 text slide, with CPU/time printed but no
timing assertions. On Koza (M5, 16 GB), one debug synthetic run including Vision's
first-use overhead recognized five frames in 39.27 s, with 4.79 process CPU seconds;
1000 unchanged-frame comparisons took 1.89 s. Process CPU excludes any framework
service work; this is not an end-to-end capture, thermal, or OCR-accuracy benchmark.
It supports deferring OCR until stop rather than paying for it at every live sample.
The same switch runs `screenFiveKFrameCPUBenchmark` on synthetic 5120×2880 text slides.
On an M4 Pro (48 GB), debug build, three runs while other builds shared the machine:
fingerprint 5–21 ms process CPU per sample (the stream itself delivers 2560×1440, so
less in practice), copying a 2560×1440 buffer through the software CIContext 4–6 ms
per sample, and downscale plus JPEG 58–64 ms per kept frame, at about 234 KiB per
JPEG. At one sample every two seconds that is under 2% of one core between keyframes.
A 2560×1440 frame of random noise (JPEG's worst case) still fits 1 MiB after
re-encoding (`denseFramesAreReencodedSmallerInsteadOfEndingTheCapture`), and a 5K frame
is stored at 2560×1440 within the caps (`fiveKFramesAreStoredWithinTheDimensionAndByteBounds`).
At ~250 KiB per frame the 256 MiB total allows about a thousand keyframes, the frame
cap; a meeting that reaches either stops screen capture and says so, and audio goes on.
`screenTwoDisplayPipelineBenchmark` (same switch) feeds synthetic 2560×1440 frames
through pixel buffers, the software CIContext copy, the per-display state, JPEG encoding
and a temporary archive, without any stream. On Koza (M5, 16 GB), debug build, three
runs: one busy display (a new slide every other sample) 20–21 ms process CPU per
two-second round (about 1% of one core), +28 MiB peak footprint; a busy display beside
a still one (idle samples) 22–24 ms, +28–29 MiB; two busy displays 43–47 ms (about 2.2%
of one core), +42–43 MiB, at about 307 KiB per JPEG. Unverified: ScreenCaptureKit's and
the window server's own work and buffer pools for each extra stream (outside this
process's CPU and footprint), and real multi-display capture and what ScreenCaptureKit
does when a display is unplugged, which no test runs.
`scripts/preview-screen-choice.swift` renders the Settings row and the start panel's
Screen row (checked, unchecked, no permission) offscreen in light and dark appearances
without launching Holos. Manual checks still required: granted/denied permission, that
Voice is Local's own windows (live transcript, Review, menu) are absent from saved
snapshots, desktop notifications, a video call next to a shared slide, scrolling,
pause/restart, audio-only survival of capture failure, deletion, two displays (both
captured, Voice is Local's windows absent from each, Screen Text labels), unplugging a
display during a meeting (its stream ends, the other goes on) and plugging one in (not
captured until the next epoch or meeting), mirroring, closing the lid on a laptop with
an external display, `--screen main`, the shared caps on a long meeting, and the full start, Settings, recording indicator, and Review UI in both
appearances. These checks must not be run by agents against the user's running
app or real meeting content.
