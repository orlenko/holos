import AppKit
import Testing
@testable import HolosApp

@MainActor
struct ReviewSurfaceTests {
    @Test func embeddingMovesTheContentAndClosingRequestsNavigationOnce() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let owned = ReviewKeyWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600),
                                   styleMask: [.titled], backing: .buffered, defer: true)
        let content = NSView()
        owned.contentView = content
        let host = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700),
                            styleMask: [.titled], backing: .buffered, defer: true)
        let surface = ReviewSurface(owned)
        var closes = 0
        #expect(surface.embed(in: host, onClose: { closes += 1 }) === content)
        #expect(owned.contentView == nil)
        #expect(surface.window === host)
        #expect(surface.isEmbedded)
        #expect(surface.embed(in: host, onClose: {}) == nil)
        surface.close()
        surface.close()
        #expect(closes == 1)
        #expect(!owned.isVisible && !host.isVisible)
    }
}
