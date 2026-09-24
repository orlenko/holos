import Foundation
import HolosCore

/// What the disk policy says about the free space on the sessions volume.
public enum DiskVerdict: Sendable, Equatable {
    case ok
    case warn(String)
    case refuse(String)
    case stop(String)
}

/// Free-space rules for recording and post-processing (docs/meeting-design.md §4.5). Pure functions; sizes are
/// decimal (1 GB = 10⁹ bytes), matching the UI.
public enum DiskPolicy {
    /// 48 kHz mono Int16 capture: 345.6 MB per hour per track.
    static let trackBytesPerHour: Int64 = 48_000 * 2 * 3_600
    static let gigabyte: Int64 = 1_000_000_000
    /// Free space kept on top of a start budget.
    static let startReserve: Int64 = 2 * gigabyte
    static let runtimeStop: Int64 = 500_000_000
    static let runtimeWarn: Int64 = 2 * gigabyte
    static let runtimeRearm: Int64 = 2_500_000_000
    static let renderHeadroom: Int64 = gigabyte

    /// Nominal Int16 capture: mic 48 kHz mono 345.6 MB/h; system 48 kHz mono 345.6 MB/h
    /// (ScreenCaptureKit channelCount = 1).
    public static func captureBytesPerHour(_ source: AudioSource) -> Int64 {
        trackBytesPerHour * Int64(trackCount(source))
    }

    /// 16 kHz mono Int16 render per diarized track: 115.2 MB/h (deleted after diarization).
    public static let renderBytesPerHour: Int64 = 115_200_000

    /// capture + render for every track, per hour.
    public static func budgetBytesPerHour(_ source: AudioSource) -> Int64 {
        captureBytesPerHour(source) + renderBytesPerHour * Int64(trackCount(source))
    }

    /// refuse if free < 4 h budget + 2 GB; warn if free < 8 h budget + 2 GB.
    public static func startCheck(freeBytes: Int64, source: AudioSource) -> DiskVerdict {
        let perHour = budgetBytesPerHour(source)
        let refuseBelow = 4 * perHour + startReserve
        let warnBelow = 8 * perHour + startReserve
        if freeBytes < refuseBelow {
            return .refuse("Not enough free disk space to record: \(gigabytes(freeBytes)) GB free, and a 4-hour recording needs \(gigabytes(refuseBelow)) GB. Free up space and try again.")
        }
        if freeBytes < warnBelow {
            let hours = Double(freeBytes - startReserve) / Double(perHour)
            return .warn("Free disk space is low (\(gigabytes(freeBytes)) GB free, enough for about \(hoursText(hours.rounded(.down))) of recording). The recording stops by itself if space runs out.")
        }
        return .ok
    }

    /// stop if free < 500 MB; warn once below 2 GB; re-arm the warning after free > 2.5 GB.
    public static func runtimeCheck(freeBytes: Int64, warned: Bool) -> (verdict: DiskVerdict, warned: Bool) {
        if freeBytes < runtimeStop {
            return (.stop("Free disk space fell below 500 MB (\(megabytes(freeBytes)) MB free); the recording stopped to keep the saved audio safe."), warned)
        }
        if freeBytes < runtimeWarn {
            if warned { return (.ok, true) }
            return (.warn("Free disk space is below 2 GB (\(gigabytes(freeBytes)) GB free); the recording stops by itself below 500 MB."), true)
        }
        if freeBytes > runtimeRearm { return (.ok, false) }
        return (.ok, warned)
    }

    /// Post-processing: render allowed only if free ≥ renderBytes + 1 GB, where renderBytes is `renderSeconds` of
    /// 16 kHz mono Int16 for each of `tracks`.
    public static func renderCheck(freeBytes: Int64, renderSeconds: Double, tracks: Int) -> Bool {
        guard renderSeconds.isFinite, renderSeconds >= 0, tracks >= 0 else { return false }
        let renderBytes = renderSeconds / 3_600 * Double(renderBytesPerHour) * Double(tracks)
        return Double(freeBytes) >= renderBytes + Double(renderHeadroom)
    }

    /// "≈1.0 GB for 3 h · 24.1 GB free" (capture only, one decimal).
    public static func estimateText(source: AudioSource, hours: Double, freeBytes: Int64) -> String {
        let bytes = Double(captureBytesPerHour(source)) * max(0, hours.isFinite ? hours : 0)
        return "≈\(gigabytes(bytes)) GB for \(hoursText(hours)) · \(gigabytes(freeBytes)) GB free"
    }

    // MARK: - Formatting

    private static func trackCount(_ source: AudioSource) -> Int { source == .microphoneAndSystem ? 2 : 1 }

    private static func gigabytes(_ bytes: Int64) -> String { gigabytes(Double(bytes)) }

    private static func gigabytes(_ bytes: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), bytes / Double(gigabyte))
    }

    private static func megabytes(_ bytes: Int64) -> String { String(max(0, bytes) / 1_000_000) }

    private static func hoursText(_ hours: Double) -> String {
        guard hours.isFinite, hours.magnitude < 1e9 else { return "? h" }
        if hours == hours.rounded() { return "\(Int(hours)) h" }
        return String(format: "%.1f h", locale: Locale(identifier: "en_US_POSIX"), hours)
    }
}
