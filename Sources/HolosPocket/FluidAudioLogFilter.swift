import Darwin
import Foundation
import Synchronization

/// Keeps FluidAudio's quiet log lines out of a file descriptor (stderr). FluidAudio's `AppLogger` writes every message
/// to stderr in a debug build, and Pocket TTS logs each chunk of text it speaks at the info level, so the text being
/// read would reach the terminal, or the app's helper log. Once installed, a pipe takes the descriptor's place and a
/// thread copies every line but FluidAudio's debug, info and notice ones (`isQuiet`) to where it went before;
/// warnings and errors still go through.
///
/// Invariants:
/// 1. Between `install` and `finish`, the descriptor writes into the pipe; after `finish` it is the original again.
/// 2. `finish` returns once every line written before it has been copied or dropped; a second `finish` does nothing.
public final class FluidAudioLogFilter: Sendable {
    private let descriptor: Int32
    private let original: Int32
    private let drained: DispatchSemaphore
    private let finished = Mutex(false)

    private init(descriptor: Int32, original: Int32, drained: DispatchSemaphore) {
        self.descriptor = descriptor
        self.original = original
        self.drained = drained
    }

    /// Whether `line` is a FluidAudio message below a warning: `[time] [INFO] [FluidAudio.<category>] …`.
    public static func isQuiet(_ line: Substring) -> Bool {
        guard let range = line.range(of: "] [FluidAudio.") else { return false }
        let head = line[..<range.lowerBound]
        return ["[DEBUG", "[INFO", "[NOTICE"].contains { head.hasSuffix($0) }
    }

    /// Puts the filter in front of `descriptor`; nil when the pipe or the copy of the descriptor cannot be made (the
    /// descriptor is then left as it was).
    public static func install(on descriptor: Int32) -> FluidAudioLogFilter? {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { return nil }
        let original = dup(descriptor)
        guard original >= 0, dup2(ends[1], descriptor) >= 0 else {
            close(ends[0])
            close(ends[1])
            if original >= 0 { close(original) }
            return nil
        }
        close(ends[1])
        let drained = DispatchSemaphore(value: 0)
        let reading = ends[0]
        Thread {
            copyLines(from: reading, to: original)
            close(reading)
            drained.signal()
        }.start()
        return FluidAudioLogFilter(descriptor: descriptor, original: original, drained: drained)
    }

    /// Puts the original descriptor back and waits for the lines already written (invariants 1 and 2).
    public func finish() {
        guard finished.withLock({ value in defer { value = true }; return !value }) else { return }
        // The pipe's last write end goes with this, so the copying thread reads to its end and stops.
        _ = dup2(original, descriptor)
        drained.wait()
        close(original)
    }

    private static func copyLines(from reading: Int32, to target: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        func emit(_ line: Data) {
            let text = String(decoding: line, as: UTF8.self)
            guard !isQuiet(text[...]) else { return }
            line.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(target, bytes.baseAddress! + offset, bytes.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
        while true {
            let count = read(reading, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                emit(pending[pending.startIndex...newline])
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty { emit(pending) }
    }
}
