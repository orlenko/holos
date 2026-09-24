import AppKit

/// Standard keyboard behaviour for Holos's windows. As a menu bar app Holos has no visible main menu, but AppKit
/// still routes key equivalents through `NSApp.mainMenu`: without one, ⌘W, ⌘C, ⌘V, ⌘A and ⌘Z do nothing in its
/// windows. Escape closes a window unless something in it handles Escape first.
@MainActor
enum AppKeyboard {
    private static var escapeMonitor: Any?

    static func install(isDictating: @escaping @MainActor () -> Bool) {
        NSApp.mainMenu = mainMenu()
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread.
            let closed = MainActor.assumeIsolated { closeOnEscape(event, isDictating: isDictating) }
            return closed ? nil : event
        }
    }

    /// Whether Escape closed the key window. A button whose key equivalent is Escape (a Cancel button), a text
    /// field being edited, a modal alert, a sheet, a window without a close button, and a dictation in progress
    /// (Escape cancels it) all keep their usual Escape.
    private static func closeOnEscape(_ event: NSEvent, isDictating: () -> Bool) -> Bool {
        guard event.keyCode == 53,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              NSApp.modalWindow == nil, !isDictating(),
              let window = NSApp.keyWindow, window.styleMask.contains(.closable), window.attachedSheet == nil,
              !(window.firstResponder is NSTextView)
        else { return false }
        if window.performKeyEquivalent(with: event) { return true }
        window.performClose(nil)
        return true
    }

    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String,
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        submenu("Holos", [item("Quit Holos", #selector(NSApplication.terminate(_:)), "q")])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let close = item("Close", #selector(NSWindow.performClose(_:)), "w")
        let minimize = item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        submenu("Window", [close, minimize])
        NSApp.windowsMenu = main.items.last?.submenu
        return main
    }
}
