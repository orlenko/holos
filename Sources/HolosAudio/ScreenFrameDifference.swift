import CoreGraphics
import Foundation

/// Spatially distributed changes, compared with the retained frame (not the last sample), on a 160×90 grayscale
/// fingerprint split into 16×9 tiles. A tile changed when at least 6 of its 100 pixels moved by 20/255.
///
/// The whole display is captured, so a video call's moving faces can cover a large part of it. `settledChange`
/// keeps a sample only when enough tiles both differ from the retained frame and stayed the same since the previous
/// sample: a new slide or a finished scroll settles, a video tile keeps moving and never counts.
public enum ScreenFrameDifference {
    public static let width = 160
    public static let height = 90
    static let columns = 16
    static let rows = 9
    /// The share of the 144 tiles that must change: 10 % (15 tiles). A cursor or a small video tile stays below it.
    public static let tileShare = 0.10

    /// The frame drawn down to 160×90 (from up to 2560×1440, or 5120×2880 in tests) with high interpolation quality,
    /// so every source pixel weighs in rather than a sample of them.
    public static func fingerprint(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Which tiles differ between two fingerprints, row by row; nil when either is not a fingerprint.
    static func changedTiles(_ next: [UInt8], _ previous: [UInt8]) -> [Bool]? {
        guard next.count == width * height, previous.count == next.count else { return nil }
        var tiles = [Bool](repeating: false, count: rows * columns)
        let tileWidth = width / columns, tileHeight = height / rows
        for row in 0..<rows {
            for column in 0..<columns {
                var changed = 0
                for y in row * tileHeight..<(row + 1) * tileHeight {
                    for x in column * tileWidth..<(column + 1) * tileWidth {
                        let index = y * width + x
                        if abs(Int(next[index]) - Int(previous[index])) >= 20 { changed += 1 }
                    }
                }
                tiles[row * columns + column] = changed >= 6
            }
        }
        return tiles
    }

    private static func enough(_ count: Int) -> Bool { Double(count) / Double(rows * columns) >= tileShare }

    /// Enough tiles differ from `previous` (any change, settled or not). True without a previous fingerprint.
    public static func meaningful(_ next: [UInt8], comparedWith previous: [UInt8]?) -> Bool {
        guard next.count == width * height else { return false }
        guard let previous else { return true }
        guard let tiles = changedTiles(next, previous) else { return true }
        return enough(tiles.filter { $0 }.count)
    }

    /// No tile differs at all: the same picture, as far as the fingerprint can tell.
    public static func unchanged(_ next: [UInt8], comparedWith previous: [UInt8]) -> Bool {
        changedTiles(next, previous).map { !$0.contains(true) } ?? false
    }

    /// Enough tiles differ from `retained` and are unchanged since `previousSample`. True without a retained
    /// fingerprint (the first frame, or the first after a gap); without a previous sample, any change counts.
    public static func settledChange(_ next: [UInt8], retained: [UInt8]?, previousSample: [UInt8]?) -> Bool {
        guard next.count == width * height else { return false }
        guard let retained, let fromRetained = changedTiles(next, retained) else { return true }
        guard let previousSample, let fromPrevious = changedTiles(next, previousSample) else {
            return enough(fromRetained.filter { $0 }.count)
        }
        return enough(zip(fromRetained, fromPrevious).filter { $0 && !$1 }.count)
    }
}
