# HolosDesktop

Where the app touches other apps: dictation's global hotkey and putting text into the focused field, and the
read-aloud shortcut and reading the selected text.

**Owns**
- `GlobalHotkeyMonitor` (`@MainActor`): a `CGEvent` tap for the chosen `HotkeyChoice`, reporting `HotkeyAction`s;
  `HotkeyStartError` says why it could not start (Accessibility not granted, tap refused). The press/release logic
  is a pure `HotkeyReducer`.
- `ChordHotkey` (`@MainActor`): a Carbon hot key for a key chord (`readSelection`, ⌃⌥⌘R), needing no permission;
  `ChordHotkeyError` says when another app holds it.
- `SelectedText` (`@MainActor`): the front app's selected text through Accessibility, never through the pasteboard;
  `SelectedTextError` says why there is none.
- `TextInsertion` (`@MainActor`): `captureTarget()` snapshots the focused element and selection at key-down as an
  `InsertionTarget`; insertion rechecks it and reports an `InsertionOutcome` (`inserted`, `typed`, `needsCopy`,
  `targetChanged`, `unverified`). `KeystrokeTarget` types into terminals. Secure input is detected and refused.

**Must not own:** dictation state (`HolosDictation`), the dictated text's history or storage, windows. It never
writes to the pasteboard: when text cannot be inserted it returns `needsCopy` and the user chooses Copy Result.

**Depends on:** HolosCore. AppKit, ApplicationServices (Accessibility), Carbon, CoreGraphics, CryptoKit.

**Invariants**
- Insertion checks the target captured at key-down before writing; a changed target gives `targetChanged`.
  `inserted` is reported only after the text is read back; keystrokes typed into a terminal cannot be read back
  (`typed`), and focus that moves while typing gives `unverified`.
- `GlobalHotkeyMonitor`, `TextInsertion`, `InsertionTarget` and `KeystrokeTarget` are `@MainActor`;
  `InsertionTarget` keeps its `AXUIElement` file-private.

**Tests:** `Tests/HolosDesktopTests` (`HotkeyReducerTests`, `TextInsertionPolicyTests`, `TerminalFocusTests`,
`HotkeyPermissionTests`, `SelectedTextTests`): policies and reducers, no events posted to other apps.
