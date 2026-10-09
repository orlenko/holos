# HolosDesktop

The two places dictation touches other apps: the global hotkey and putting text into the focused field.

**Owns**
- `GlobalHotkeyMonitor` (`@MainActor`): a `CGEvent` tap for the chosen `HotkeyChoice`, reporting `HotkeyAction`s;
  `HotkeyStartError` says why it could not start (Accessibility not granted, tap refused). The press/release logic
  is a pure `HotkeyReducer`.
- `TextInsertion` (`@MainActor`): `captureTarget()` snapshots the focused element and selection at key-down as an
  `InsertionTarget`; insertion rechecks it and reports an `InsertionOutcome` (`inserted`, `typed`, `needsCopy`,
  `targetChanged`, `unverified`). `KeystrokeTarget` types into terminals. Secure input is detected and refused.

**Must not own:** dictation state (`HolosDictation`), the dictated text's history or storage, windows. It never
writes to the pasteboard: when text cannot be inserted it returns `needsCopy` and the user chooses Copy Result.

**Depends on:** HolosCore. AppKit, ApplicationServices (Accessibility), Carbon, CoreGraphics, CryptoKit.

**Invariants**
- Insertion never lands somewhere other than the target captured at key-down; a changed target gives
  `targetChanged`, and success is reported only when it can be verified (terminals give `typed`).
- Everything runs on the main actor; Accessibility objects never leave it.

**Tests:** `Tests/HolosDesktopTests` (`HotkeyReducerTests`, `TextInsertionPolicyTests`, `TerminalFocusTests`,
`HotkeyPermissionTests`): policies and reducers, no events posted to other apps.
