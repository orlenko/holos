# Future mobile apps (notes, not started)

Voice is Local is a Mac app today. These notes record what a local-only iOS or Android version could look like,
so the idea can be picked up later. They come from general knowledge of the platforms as of September 2026 and
have **not** been checked against current SDK documentation or prototyped. Treat every API claim here as something
to verify first.

## iOS: reuse most of the engine

- **Speech and fixing:** Apple's SpeechAnalyzer/SpeechTranscriber and Foundation Models, which the Mac app uses,
  also exist on iOS. The on-device misheard-word fix needs an Apple Intelligence iPhone.
- **Speaker labels:** FluidAudio is Core ML and should run on iPhone. The session format (`.holos`), speaker
  alignment and voice profiles are plain Swift and should carry over largely unchanged (HolosCore, HolosStorage,
  HolosSpeakers, most of HolosMeeting).
- **Dictation into other apps (hard part):** iOS has no global hotkey and does not let an app type into other apps.
  The usual pattern is a custom keyboard paired with the main app: the keyboard hands off to the app to record
  (keyboard extensions are understood not to get microphone access), then inserts the result. It works but is less
  direct than holding a key on the Mac.
- **Meetings:** microphone recording can run in the background for long meetings. iOS does not let an app capture
  other apps' audio or phone calls, so a call on the phone reaches the recording only through the speaker.
- **Rewrite:** the UI (AppKit today) would be SwiftUI.

## Android: same design, new code

- **Speech:** Android 13+ has an on-device recognizer, with quality that varies by device maker. For consistent
  local results, bundle an open model runtime such as sherpa-onnx (streaming recognition and speaker diarization)
  or whisper.cpp.
- **Fixing:** Google's on-device Gemini Nano (ML Kit GenAI, including proofreading) on supported devices.
- **Dictation into other apps (easier than iOS):** a custom keyboard (IME) may use the microphone and stream text
  into any field.
- **Meetings:** microphone recording in a foreground service. Capturing other apps' audio (AudioPlaybackCapture,
  Android 10+) is blocked by most call apps; phone calls cannot be recorded.
- **Rewrite:** Kotlin. What carries over is the design, the session file format and the lessons learned. Swift on
  Android exists but is early.

## Suggested order when this is picked up

1. iOS first: a meeting recorder plus the keyboard/app pair, reusing the Swift packages.
2. Start with a short spike on a real iPhone: the keyboard-to-app recording handoff, SpeechTranscriber streaming,
   and FluidAudio diarization memory and speed.
3. Android as a separate project, porting the design and the `.holos` format rather than the code.
