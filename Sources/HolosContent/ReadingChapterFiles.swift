import AVFoundation
import Foundation
import HolosCore
import HolosSynthesis

/// A finished reading as one audio file per chapter, with a playlist (docs/design.md "Reading section"): a folder to
/// copy to a phone or a shared drive, where picking up at a chapter is easier than finding a time in one long file.
/// The audio is copied from the finished file, not encoded again, so it takes moments and needs no render cache.
///
/// Invariants:
/// 1. The tracks cover the whole reading, in order, with no gap and no overlap.
/// 2. The folder appears whole or not at all: it is made under a hidden name, and named last.
/// 3. Nothing already there is replaced: a folder of that name gets a number after it.
/// 4. The playlist names each track by the very bytes of its file's name, as another system compares them.
public enum ReadingChapterFiles {
    public struct Track: Sendable, Equatable {
        public let title: String
        public let start: Double
        public let end: Double
        public let fileName: String
    }

    /// The tracks for `chapters` of a reading `duration` long; nil with fewer than two: one file says it all.
    public static func tracks(chapters: [AudioBookChapter], duration: Double) -> [Track]? {
        // Each after the one before: an empty stretch is no track.
        let ordered = chapters.reduce(into: [AudioBookChapter]()) { kept, chapter in
            if chapter.start < duration, chapter.start > kept.last?.start ?? -1 { kept.append(chapter) }
        }
        guard ordered.count >= 2 else { return nil }
        let width = max(2, String(ordered.count).count)
        return ordered.indices.map { index in
            let number = String(format: "%0\(width)d", index + 1)
            let name = ReadingOutput.fileName(title: "\(number) \(ordered[index].title)", fallback: "\(number) Chapter")
            return Track(title: ordered[index].title, start: index == 0 ? 0 : ordered[index].start,
                         end: index + 1 < ordered.count ? ordered[index + 1].start : duration, fileName: name)
        }
    }

    static let playlistName = "Playlist.m3u8"
    /// How long one chapter's copy may take, on a drive or a share that may have stopped answering.
    public static let trackTimeout: Duration = .seconds(600)

    /// An extended M3U playlist of `tracks`, by the names beside it.
    public static func playlist(title: String, tracks: [Track]) -> String {
        // One line each: a title's line break would read as another track.
        func oneLine(_ text: String) -> String {
            text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        var lines = ["#EXTM3U", "#PLAYLIST:\(oneLine(title))"]
        for track in tracks {
            lines.append("#EXTINF:\(Int((track.end - track.start).rounded())),\(oneLine(track.title))")
            lines.append(track.fileName)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Makes the folder for the finished file `source` inside `parent`, and returns it. `done`: tracks finished so far.
    public static func make(from source: URL, title: String, author: String?, chapters: [AudioBookChapter],
                            duration: Double, in parent: URL, timeout: Duration = trackTimeout,
                            done: (@Sendable (Int, Int) -> Void)? = nil) async throws -> URL {
        guard let tracks = tracks(chapters: chapters, duration: duration) else {
            throw HolosError.invalidInput("This reading has no chapters to make files of.")
        }
        let folderName = String(ReadingOutput.fileName(title: title, fallback: "Reading").dropLast(ReadingOutput.fileExtension.count))
        // Not named after the title: a name that just fits with its extension would not fit with this.
        let temporary = parent.appendingPathComponent(".holos-chapters-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            let asset = AVURLAsset(url: source)
            for (index, track) in tracks.enumerated() {
                try Task.checkCancellation()
                try await bounded(by: timeout) {
                    try await export(asset, track, album: title, author: author,
                                     to: RawFilePath.appending(track.fileName, to: temporary))
                }
                done?(index + 1, tracks.count)
            }
            try Data(playlist(title: title, tracks: tracks).utf8)
                .write(to: temporary.appendingPathComponent(playlistName), options: .withoutOverwriting)
            return try publish(temporary, named: folderName, in: parent)
        } catch {
            do {
                try FileManager.default.removeItem(at: temporary)
            } catch let removal {
                throw HolosError.io("\(error.localizedDescription) Its unfinished folder is left at \(temporary.path): "
                    + removal.localizedDescription)
            }
            throw error
        }
    }

    /// `work`, cancelled and reported as a failure if it is not done within `limit`.
    static func bounded(by limit: Duration, _ work: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await work()
                return true
            }
            group.addTask {
                try await Task.sleep(for: limit)
                return false
            }
            let finished = try await group.next() ?? false
            group.cancelAll()
            guard finished else { throw HolosError.io("Copying a chapter did not finish in time.") }
        }
    }

    private static func export(_ asset: AVURLAsset, _ track: Track, album: String, author: String?, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw HolosError.unavailable("The audio could not be copied.")
        }
        let scale: CMTimeScale = 44_100
        session.timeRange = CMTimeRange(start: CMTime(seconds: track.start, preferredTimescale: scale),
                                        end: CMTime(seconds: track.end, preferredTimescale: scale))
        session.metadata = [(AVMetadataIdentifier.iTunesMetadataSongName, track.title),
                            (.iTunesMetadataAlbum, album), (.iTunesMetadataArtist, author)]
            .compactMap { identifier, value in
                guard let value else { return nil }
                let item = AVMutableMetadataItem()
                item.identifier = identifier
                item.value = value as NSString
                return item
            }
        try await session.export(to: output, as: .m4a)
    }

    /// Invariants 2 and 3: a move refuses a name already taken.
    private static func publish(_ temporary: URL, named name: String, in parent: URL) throws -> URL {
        for attempt in 1...999 {
            let target = parent.appendingPathComponent(attempt == 1 ? name : "\(name) \(attempt)", isDirectory: true)
            do {
                try FileManager.default.moveItem(at: temporary, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw HolosError.io("No free name for the chapter files in \(parent.path).")
    }
}
