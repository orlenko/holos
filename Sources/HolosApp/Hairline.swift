import AppKit

extension NSBox {
    /// A horizontal separator line one point high: the only way the app makes a separator box (`HairlineTests` fails on
    /// any other). A separator box has no height of its own under Auto Layout, so without the height constraint the
    /// space around it was split between it and its neighbour at random, and in tall windows the line took all of it
    /// (the blank Settings page of #82, the blank live transcript of #90). Its hugging and compression resistance are
    /// required too, so nothing in a stack view stretches or squeezes it.
    static func hairline() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        box.setContentHuggingPriority(.required, for: .vertical)
        box.setContentCompressionResistancePriority(.required, for: .vertical)
        return box
    }
}
