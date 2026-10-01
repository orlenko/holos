import CoreGraphics
import Foundation

/// Spatially distributed changes, compared with the retained frame (not the last sample).
/// A cursor or a video tile changing less than 18% of the image's tiles is ignored.
public enum ScreenFrameDifference {
    public static let width = 160
    public static let height = 90
    public static func fingerprint(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    public static func meaningful(_ next: [UInt8], comparedWith previous: [UInt8]?) -> Bool {
        guard next.count == width * height else { return false }
        guard let previous, previous.count == next.count else { return true }
        var tiles = 0
        for row in 0..<9 {
            for column in 0..<16 {
                var changed = 0
                for y in row * 10..<(row + 1) * 10 {
                    for x in column * 10..<(column + 1) * 10 {
                        let index = y * width + x
                        if abs(Int(next[index]) - Int(previous[index])) >= 20 { changed += 1 }
                    }
                }
                if changed >= 6 { tiles += 1 }
            }
        }
        return Double(tiles) / 144 >= 0.18
    }
}
