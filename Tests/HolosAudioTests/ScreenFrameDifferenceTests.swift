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

/// Invented 160×90 fingerprints: white, with blocks of `gray` over the given tiles (16×9 tiles of 10×10 pixels).
private func tiles(_ blocks: [(columns: Range<Int>, rows: Range<Int>, gray: UInt8)]) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: 160 * 90)
    for block in blocks {
        for y in block.rows.lowerBound * 10..<block.rows.upperBound * 10 {
            for x in block.columns.lowerBound * 10..<block.columns.upperBound * 10 { pixels[y * 160 + x] = block.gray }
        }
    }
    return pixels
}

@Test func settledChangeIgnoresAMovingVideoButKeepsASlideNextToIt() {
    // A video call fills the left half (72 tiles) and changes every sample; a shared slide sits on the right.
    let video1 = (columns: 0..<8, rows: 0..<9, gray: UInt8(40))
    let video2 = (columns: 0..<8, rows: 0..<9, gray: UInt8(160))
    let retained = tiles([video1])
    let moving = tiles([video2])
    #expect(ScreenFrameDifference.meaningful(moving, comparedWith: retained), "half the display changed")
    #expect(!ScreenFrameDifference.settledChange(moving, retained: retained, previousSample: retained))
    // A new slide (24 tiles, 17 %) appears while the video keeps changing: it settles on its second sample.
    let video3 = (columns: 0..<8, rows: 0..<9, gray: UInt8(100))
    let slide = (columns: 10..<16, rows: 2..<6, gray: UInt8(0))
    let first = tiles([video3, slide])
    let second = tiles([video2, slide])
    #expect(!ScreenFrameDifference.settledChange(first, retained: retained, previousSample: moving))
    #expect(ScreenFrameDifference.settledChange(second, retained: retained, previousSample: first))
}

@Test func settledChangeKeepsTheFirstFrameAndNeedsATenthOfTheDisplay() {
    let blank = tiles([])
    #expect(ScreenFrameDifference.settledChange(blank, retained: nil, previousSample: nil))
    #expect(!ScreenFrameDifference.settledChange([], retained: nil, previousSample: nil))
    // 14 tiles (9.7 %) stay below the 10 % share; 15 tiles reach it.
    let fourteen = tiles([(columns: 0..<14, rows: 0..<1, gray: 0)])
    let fifteen = tiles([(columns: 0..<15, rows: 0..<1, gray: 0)])
    #expect(!ScreenFrameDifference.settledChange(fourteen, retained: blank, previousSample: fourteen))
    #expect(ScreenFrameDifference.settledChange(fifteen, retained: blank, previousSample: fifteen))
    #expect(ScreenFrameDifference.settledChange(fifteen, retained: blank, previousSample: nil))
}

@Test func fiveKFingerprintSeesThinTextMoveButNotAnIdenticalFrame() throws {
    let slide = try #require(syntheticDisplay())
    let same = try #require(syntheticDisplay())
    let next = try #require(syntheticDisplay(offset: 90))
    let a = try #require(ScreenFrameDifference.fingerprint(slide))
    let b = try #require(ScreenFrameDifference.fingerprint(same))
    let c = try #require(ScreenFrameDifference.fingerprint(next))
    #expect(!ScreenFrameDifference.meaningful(b, comparedWith: a))
    #expect(ScreenFrameDifference.meaningful(c, comparedWith: a), "the next slide's text sits on other rows")
}

/// A synthetic display (5K by default): white, with rows of dark 6-pixel-tall dashes like a slide's text, moved
/// down by `offset` pixels. Invented pixels only.
func syntheticDisplay(width: Int = 5120, height: Int = 2880, lines: Int = 12, offset: Int = 0) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1)
    let pitch = height / (lines + 2)
    for line in 0..<lines {
        var x = width / 10, word = line
        while x < width * 9 / 10 {
            let length = 40 + (word * 37) % 160
            for row in 0..<3 {
                context.fill(CGRect(x: x, y: pitch * (line + 1) + offset + row * 12, width: length, height: 6))
            }
            x += length + 30
            word += 1
        }
    }
    return context.makeImage()
}
