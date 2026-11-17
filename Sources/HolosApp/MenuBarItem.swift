import AppKit

/// Items of the menu bar menu (docs/design.md "Menu bar menu").
@MainActor
enum MenuBarItem {
    /// Start Meeting Recording… and Stop and Save…: a red symbol and bold type set them apart from the plain items, so
    /// they are found at a glance when a call starts. A disabled one is grey: an attributed title keeps its own colour.
    static func prominent(_ title: String, symbol: String, target: AnyObject, action: Selector,
                          enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.isEnabled = enabled
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(hierarchicalColor: enabled ? .systemRed : .disabledControlTextColor))
        let font = NSFontManager.shared.convert(NSFont.menuFont(ofSize: 0), toHaveTrait: .boldFontMask)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if !enabled { attributes[.foregroundColor] = NSColor.disabledControlTextColor }
        item.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        return item
    }
}
