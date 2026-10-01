import CoreGraphics
import HolosAudio
import Testing

@Test func screenDifferenceIgnoresCursorAndSmallVideoTileButKeepsNewSlide() {
    let empty = [UInt8](repeating: 255, count: 160 * 90)
    var cursor = empty
    for y in 4..<8 { for x in 5..<9 { cursor[y * 160 + x] = 0 } }
    #expect(!ScreenFrameDifference.meaningful(cursor, comparedWith: empty))
    var tile = empty
    for y in 0..<20 { for x in 0..<40 { tile[y * 160 + x] = 0 } }
    #expect(!ScreenFrameDifference.meaningful(tile, comparedWith: empty))
    var slide = empty
    for y in stride(from: 10, to: 80, by: 10) {
        for row in y..<y + 2 { for x in 20..<140 { slide[row * 160 + x] = 0 } }
    }
    #expect(ScreenFrameDifference.meaningful(slide, comparedWith: empty))
    #expect(!ScreenFrameDifference.meaningful(slide, comparedWith: slide))
    #expect(ScreenFrameDifference.meaningful(slide, comparedWith: nil))
    #expect(!ScreenFrameDifference.meaningful([], comparedWith: nil))
}

@Test func screenDifferenceKeepsScrolledDocumentComparedWithRetainedFrame() {
    var first = [UInt8](repeating: 255, count: 160 * 90)
    var scrolled = first
    for y in stride(from: 10, to: 80, by: 10) {
        for row in y..<y + 2 { for x in 20..<140 { first[row * 160 + x] = 0 } }
        for row in y + 4..<y + 6 { for x in 20..<140 { scrolled[row * 160 + x] = 0 } }
    }
    #expect(ScreenFrameDifference.meaningful(scrolled, comparedWith: first))
}

@Test func screenFingerprintUsesOnlySyntheticImage() throws {
    let context = try #require(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
        bytesPerRow: 640, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
    let image = try #require(context.makeImage())
    let pixels = try #require(ScreenFrameDifference.fingerprint(image))
    #expect(pixels.count == 160 * 90)
    #expect(pixels.allSatisfy { $0 == 255 })
}
