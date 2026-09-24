#!/usr/bin/env swift

import AVFoundation
import Darwin
import Foundation

private struct Options {
    var input: URL
    var cli: URL
    var output: URL
    var locale: String
    var backends: [String]
    var referenceFormat: String
    var pair: String?
    var timeoutSeconds: Double
    /// Speaker labels against Otter (docs/meeting-design.md §5.5 PR7c) instead of word error rate.
    var speakers = false
    /// Cross-recording centroid distances of 001 and 003 (§4.10 calibration).
    var calibrate = false
    var keepSessions = false

    var evaluatesSpeakers: Bool { speakers || calibrate }
}

private struct Transcript: Decodable {
    struct Segment: Decodable { let text: String }
    let segments: [Segment]
}

private struct PairResult: Encodable {
    let pair: String
    let backend: String
    let audioSeconds: Double
    let runtimeSeconds: Double
    let referenceWords: Int
    let hypothesisWords: Int
    let substitutions: Int
    let deletions: Int
    let insertions: Int
    let numericEdits: Int
    let wer: Double
}

private struct Aggregate: Encodable {
    let backend: String
    let files: Int
    let audioSeconds: Double
    let runtimeSeconds: Double
    let referenceWords: Int
    let hypothesisWords: Int
    let substitutions: Int
    let deletions: Int
    let insertions: Int
    let numericEdits: Int
    let microWER: Double
}

private struct Report: Encodable {
    let schemaVersion = 1
    let locale: String
    let referenceProvenance: String
    let normalization: String
    let pairs: [PairResult]
    let aggregates: [Aggregate]
}

private struct EditCounts {
    var substitutions = 0
    var deletions = 0
    var insertions = 0
    var numericEdits = 0
    var total: Int { substitutions + deletions + insertions }
}

private struct EditCell {
    var cost: Int
    var counts: EditCounts
}

private enum EvaluationError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let message): message }
    }
}

private let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
private let privateBase = cwd.appendingPathComponent(".local/evaluation", isDirectory: true).standardizedFileURL
private let wordPattern = try NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
// Same text as OtterTranscriptParser.evaluatorHeaderPattern: h:mm:ss with any number of hour digits (Holos exports
// past 99 hours), or Otter's mm:ss with one or two minute digits.
private let otterHeaderPattern = try NSRegularExpression(pattern: #"^\s*\S.*\s{2,}(?:\d+:\d{2}:\d{2}|\d{1,2}:\d{2})\s*$"#)
private let otterFooterPattern = try NSRegularExpression(pattern: #"(?i)^\s*transcribed by\s+https?://otter\.ai/?\s*$"#)

private func pathURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL
}

private let usage = """
    Usage: swift scripts/evaluate-references.swift --input DIR --cli HOLOS_BINARY [--reference-format wispr|otter] \
    [--pair ID] [--output .local/evaluation/RUN] [--locale en-CA] [--backend both|speech|dictation] \
    [--timeout-seconds 600] [--speakers] [--calibrate] [--keep-sessions]
    """

private func parseOptions() throws -> Options {
    let manager = FileManager.default
    let args = Array(CommandLine.arguments.dropFirst())
    var values: [String: String] = [:]
    var flags = Set<String>()
    var index = 0
    while index < args.count {
        let name = args[index]
        if ["--speakers", "--calibrate", "--keep-sessions"].contains(name) {
            guard flags.insert(name).inserted else { throw EvaluationError.message("Duplicate option: \(name)") }
            index += 1
            continue
        }
        guard ["--input", "--cli", "--output", "--locale", "--backend", "--reference-format", "--pair", "--timeout-seconds"].contains(name), index + 1 < args.count else {
            throw EvaluationError.message(usage)
        }
        guard values[name] == nil else { throw EvaluationError.message("Duplicate option: \(name)") }
        values[name] = args[index + 1]
        index += 2
    }
    guard let input = values["--input"], let cli = values["--cli"] else {
        throw EvaluationError.message("Provide --input and --cli. No reference text is printed.")
    }
    let speakers = flags.contains("--speakers")
    let calibrate = flags.contains("--calibrate")
    let evaluatesSpeakers = speakers || calibrate
    let backend = values["--backend"] ?? (evaluatesSpeakers ? "speech" : "both")
    let backends: [String]
    switch backend {
    case "both" where !evaluatesSpeakers: backends = ["speech", "dictation"]
    case "speech", "dictation": backends = [backend]
    default:
        throw EvaluationError.message(evaluatesSpeakers
            ? "With --speakers or --calibrate, the backend that transcribes the imports must be speech or dictation."
            : "Backend must be both, speech, or dictation.")
    }
    let referenceFormat = values["--reference-format"] ?? "wispr"
    guard ["wispr", "otter"].contains(referenceFormat) else {
        throw EvaluationError.message("Reference format must be wispr or otter.")
    }
    if evaluatesSpeakers, referenceFormat != "otter" {
        throw EvaluationError.message("--speakers and --calibrate need --reference-format otter (Otter has speaker labels).")
    }
    if flags.contains("--keep-sessions"), !evaluatesSpeakers {
        throw EvaluationError.message("--keep-sessions applies only with --speakers or --calibrate.")
    }
    // Importing a long recording transcribes it, so the speaker evaluation allows each command an hour by default.
    guard let timeoutSeconds = Double(values["--timeout-seconds"] ?? (evaluatesSpeakers ? "3600" : "600")),
          timeoutSeconds.isFinite, timeoutSeconds > 0 else {
        throw EvaluationError.message("Timeout must be a positive number of seconds.")
    }
    let runName = "run-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
    let output = values["--output"].map(pathURL) ?? privateBase.appendingPathComponent(runName, isDirectory: true)
    guard output.path.hasPrefix(privateBase.path + "/") else {
        throw EvaluationError.message("Output must be a new directory inside .local/evaluation/.")
    }
    guard !manager.fileExists(atPath: output.path) else {
        throw EvaluationError.message("Output directory already exists; choose a new run directory.")
    }
    return Options(input: pathURL(input), cli: pathURL(cli), output: output,
                   locale: values["--locale"] ?? "en-CA", backends: backends,
                   referenceFormat: referenceFormat, pair: values["--pair"], timeoutSeconds: timeoutSeconds,
                   speakers: speakers, calibrate: calibrate, keepSessions: flags.contains("--keep-sessions"))
}

private func pairedInputs(_ options: Options) throws -> [(name: String, audio: URL, reference: URL)] {
    let manager = FileManager.default
    let entries = try manager.contentsOfDirectory(at: options.input, includingPropertiesForKeys: [.isRegularFileKey],
                                                   options: [.skipsHiddenFiles])
    switch options.referenceFormat {
    case "wispr":
        let wavs = entries.filter { $0.pathExtension.lowercased() == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !wavs.isEmpty else { throw EvaluationError.message("No WAV files found in input directory.") }
        return try wavs.compactMap { wav in
            let name = wav.deletingPathExtension().lastPathComponent
            if let pair = options.pair, pair != name { return nil }
            let reference = wav.deletingPathExtension().appendingPathExtension("txt")
            guard manager.fileExists(atPath: reference.path) else {
                throw EvaluationError.message("A WAV file has no matching TXT reference: \(wav.lastPathComponent)")
            }
            return (name, wav, reference)
        }
    case "otter":
        let folders = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try folders.compactMap { folder in
            let name = folder.lastPathComponent
            if let pair = options.pair, pair != name { return nil }
            let files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles])
            let audio = files.filter { $0.pathExtension.lowercased() == "mp3" }
            let references = files.filter { $0.lastPathComponent.hasSuffix("_transcript.txt") }
            guard audio.count == 1, references.count == 1 else {
                throw EvaluationError.message("Otter pair \(name) must contain exactly one MP3 and one *_transcript.txt.")
            }
            return (name, audio[0], references[0])
        }
    default:
        throw EvaluationError.message("Unsupported reference format.")
    }
}

private func stripOtterMetadata(_ text: String) -> String {
    let lines = text.components(separatedBy: .newlines)
    var content: [String] = []
    for line in lines {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        if otterHeaderPattern.firstMatch(in: line, range: range) != nil { continue }
        if otterFooterPattern.firstMatch(in: line, range: range) != nil { continue }
        if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { content.append(line) }
    }
    return content.joined(separator: " ")
}

private func tokens(_ text: String) -> [String] {
    let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
    let source = normalized as NSString
    return wordPattern.matches(in: normalized, range: NSRange(location: 0, length: source.length))
        .map { source.substring(with: $0.range) }
}

private func isNumeric(_ token: String) -> Bool {
    token.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
}

private func editCounts(reference: [String], hypothesis: [String]) -> EditCounts {
    // Two rows of cells keep memory proportional to the shorter transcript.
    // Ties prefer substitution, then deletion, then insertion.
    let swapSides = hypothesis.count > reference.count
    let outer = swapSides ? hypothesis : reference
    let inner = swapSides ? reference : hypothesis
    var previous = [EditCell](repeating: EditCell(cost: 0, counts: EditCounts()), count: inner.count + 1)
    var current = previous
    for column in 1..<previous.count {
        previous[column] = previous[column - 1]
        previous[column].cost += 1
        if swapSides { previous[column].counts.deletions += 1 }
        else { previous[column].counts.insertions += 1 }
        if isNumeric(inner[column - 1]) { previous[column].counts.numericEdits += 1 }
    }
    if outer.isEmpty { return previous[inner.count].counts }
    for row in 1...outer.count {
        current[0] = previous[0]
        current[0].cost += 1
        if swapSides { current[0].counts.insertions += 1 }
        else { current[0].counts.deletions += 1 }
        if isNumeric(outer[row - 1]) { current[0].counts.numericEdits += 1 }
        for column in 1..<previous.count {
            if outer[row - 1] == inner[column - 1] {
                current[column] = previous[column - 1]
                continue
            }
            var substitution = previous[column - 1]
            substitution.cost += 1
            substitution.counts.substitutions += 1
            if isNumeric(outer[row - 1]) || isNumeric(inner[column - 1]) {
                substitution.counts.numericEdits += 1
            }
            var outerGap = previous[column]
            outerGap.cost += 1
            if swapSides { outerGap.counts.insertions += 1 }
            else { outerGap.counts.deletions += 1 }
            if isNumeric(outer[row - 1]) { outerGap.counts.numericEdits += 1 }
            var innerGap = current[column - 1]
            innerGap.cost += 1
            if swapSides { innerGap.counts.deletions += 1 }
            else { innerGap.counts.insertions += 1 }
            if isNumeric(inner[column - 1]) { innerGap.counts.numericEdits += 1 }
            let deletion = swapSides ? innerGap : outerGap
            let insertion = swapSides ? outerGap : innerGap
            current[column] = substitution.cost <= deletion.cost && substitution.cost <= insertion.cost
                ? substitution : (deletion.cost <= insertion.cost ? deletion : insertion)
        }
        swap(&previous, &current)
    }
    return previous[inner.count].counts
}

private func runCLI(_ options: Options, audio: URL, backend: String, output: URL) throws -> Double {
    let process = Process()
    process.executableURL = options.cli
    process.arguments = ["transcribe", audio.path, "--locale", options.locale,
                         "--backend", backend, "--output", output.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let started = ProcessInfo.processInfo.systemUptime
    try process.run()
    while process.isRunning {
        if ProcessInfo.processInfo.systemUptime - started > options.timeoutSeconds {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw EvaluationError.message("CLI transcription timed out for \(audio.lastPathComponent) using \(backend).")
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw EvaluationError.message("CLI transcription failed for \(audio.lastPathComponent) using \(backend) (status \(process.terminationStatus)).")
    }
    return ProcessInfo.processInfo.systemUptime - started
}

private func aggregate(_ rows: [PairResult], backend: String) -> Aggregate {
    let selected = rows.filter { $0.backend == backend }
    let referenceWords = selected.reduce(0) { $0 + $1.referenceWords }
    let substitutions = selected.reduce(0) { $0 + $1.substitutions }
    let deletions = selected.reduce(0) { $0 + $1.deletions }
    let insertions = selected.reduce(0) { $0 + $1.insertions }
    return Aggregate(backend: backend, files: selected.count,
                     audioSeconds: selected.reduce(0) { $0 + $1.audioSeconds },
                     runtimeSeconds: selected.reduce(0) { $0 + $1.runtimeSeconds },
                     referenceWords: referenceWords,
                     hypothesisWords: selected.reduce(0) { $0 + $1.hypothesisWords },
                     substitutions: substitutions, deletions: deletions, insertions: insertions,
                     numericEdits: selected.reduce(0) { $0 + $1.numericEdits },
                     microWER: referenceWords == 0 ? 0 : Double(substitutions + deletions + insertions) / Double(referenceWords))
}

private func markdown(_ report: Report) -> String {
    var lines = ["# Local reference evaluation", "",
                 report.referenceProvenance + ". WER measures disagreement with this reference, not verified recognition error.",
                 "Normalization: \(report.normalization).", "",
                 "| Pair | Backend | Audio s | Runtime s | Ref words | Sub | Del | Ins | Numeric edits | WER |",
                 "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in report.pairs {
        lines.append(String(format: "| %@ | %@ | %.2f | %.2f | %d | %d | %d | %d | %d | %.1f%% |",
                            row.pair, row.backend, row.audioSeconds, row.runtimeSeconds,
                            row.referenceWords, row.substitutions, row.deletions, row.insertions,
                            row.numericEdits, row.wer * 100))
    }
    lines += ["", "| Backend | Files | Audio s | Runtime s | Ref words | Sub | Del | Ins | Numeric edits | Micro WER |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in report.aggregates {
        lines.append(String(format: "| %@ | %d | %.2f | %.2f | %d | %d | %d | %d | %d | %.1f%% |",
                            row.backend, row.files, row.audioSeconds, row.runtimeSeconds,
                            row.referenceWords, row.substitutions, row.deletions, row.insertions,
                            row.numericEdits, row.microWER * 100))
    }
    return lines.joined(separator: "\n") + "\n"
}

private func evaluate() throws {
    let manager = FileManager.default
    let options = try parseOptions()
    guard manager.isExecutableFile(atPath: options.cli.path) else {
        throw EvaluationError.message("CLI binary is missing or not executable.")
    }
    if options.evaluatesSpeakers {
        try evaluateSpeakers(options)
        return
    }
    let pairs = try pairedInputs(options)
    guard !pairs.isEmpty else { throw EvaluationError.message("No pairs matched the requested --pair selection.") }
    try manager.createDirectory(at: options.output, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    var rows: [PairResult] = []
    for pair in pairs {
        let source = try String(contentsOf: pair.reference, encoding: .utf8)
        let reference = tokens(options.referenceFormat == "otter" ? stripOtterMetadata(source) : source)
        guard !reference.isEmpty else { throw EvaluationError.message("A TXT reference has no normalized words.") }
        let audio = try AVAudioFile(forReading: pair.audio)
        let seconds = Double(audio.length) / audio.processingFormat.sampleRate
        for backend in options.backends {
            let rawURL = options.output.appendingPathComponent("\(pair.name)-\(backend)-raw.json")
            let runtime = try runCLI(options, audio: pair.audio, backend: backend, output: rawURL)
            let result = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: rawURL))
            let hypothesis = tokens(result.segments.map(\.text).joined(separator: " "))
            let counts = editCounts(reference: reference, hypothesis: hypothesis)
            rows.append(PairResult(pair: pair.name, backend: backend, audioSeconds: seconds,
                                   runtimeSeconds: runtime, referenceWords: reference.count,
                                   hypothesisWords: hypothesis.count, substitutions: counts.substitutions,
                                   deletions: counts.deletions, insertions: counts.insertions,
                                   numericEdits: counts.numericEdits,
                                   wer: Double(counts.total) / Double(reference.count)))
        }
    }
    let provenance = options.referenceFormat == "otter"
        ? "Otter-exported transcript with speaker/timestamp headers and export footer removed; not verified verbatim ground truth"
        : "Wispr-exported output; unknown whether history incorporates post-dictation corrections; not verified verbatim ground truth"
    let report = Report(locale: options.locale,
                        referenceProvenance: provenance,
                        normalization: "Unicode compatibility composition, lowercase, contiguous Unicode letter/digit tokens; punctuation ignored; written and spoken numbers remain distinct",
                        pairs: rows, aggregates: options.backends.map { aggregate(rows, backend: $0) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: options.output.appendingPathComponent("summary.json"), options: [.withoutOverwriting])
    try markdown(report).write(to: options.output.appendingPathComponent("summary.md"), atomically: false, encoding: .utf8)
    print("Report: \(options.output.path)")
    for row in report.aggregates {
        print(String(format: "%@: %d files, %.1fs audio, %.1fs runtime, %d reference words, %d sub / %d del / %d ins, micro WER %.1f%%",
                     row.backend, row.files, row.audioSeconds, row.runtimeSeconds, row.referenceWords,
                     row.substitutions, row.deletions, row.insertions, row.microWER * 100))
    }
}

// MARK: - Speaker labels against Otter (docs/meeting-design.md §5.5 PR7c)

/// The recordings `--calibrate` compares: they share six named participants.
private let calibrationPairs = ["001", "003"]
/// `holos session score`'s default collar.
private let scoreCollar = 0.25

private struct CommandResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let seconds: Double
}

/// `holos session diarize --json`: the fields the evaluation reads.
private struct DiarizeRecord: Decodable {
    struct Stage: Decodable {
        let stage: String
        let result: String
        let seconds: Double
    }
    let state: String
    let runID: String?
    let message: String?
    let stages: [Stage]
}

/// `holos session score --json`: counts, ratios, cluster IDs, and hashed Otter labels only.
private struct ScoreReport: Decodable {
    let runID: String
    let audioSeconds: Double
    let referenceSpeakers: Int
    let referenceSpeakersOver30s: Int
    let holosSpeakers: Int
    let holosSpeakersOver30s: Int
    let agreementConfusion: Double
    let comparedSeconds: Double
    let mappingSize: Int
    let mapping: [String: String]
    let genericLabels: [String]
    let turnAgreementConfusion: Double
    let turnComparedSeconds: Double
    let trackOffsets: [String: Double]
    let engineConfiguration: [String: String]
}

/// `speakers/voice/<run>.json` (written only with the hidden `--voice-data`): cluster ID → base64 Float32 centroid.
private struct VoiceData: Decodable {
    let centroids: [String: String]
}

private struct ImportRow: Encodable {
    let pair: String
    let audioSeconds: Double
    /// `holos session import`: copying the audio and transcribing it once.
    let importSeconds: Double
}

private struct SpeakerRow: Encodable {
    let pair: String
    let configuration: String
    let speakerHint: String?
    let exclusiveSegments: String?
    let referenceSpeakers: Int
    let referenceSpeakersOver30s: Int
    let holosSpeakers: Int
    let holosSpeakersOver30s: Int
    /// Agreement with Otter over the diarization segments.
    let agreementConfusion: Double
    let comparedSeconds: Double
    /// Agreement with Otter over the labelled turns.
    let turnAgreementConfusion: Double
    let turnComparedSeconds: Double
    let mappedSpeakers: Int
    /// The post-processor's diarize stage (FluidAudio, one pass over the track).
    let diarizationSeconds: Double
    /// The whole `holos session diarize` process: render, diarize, align, exports.
    let commandSeconds: Double
    let peakRSSBytes: Int?
    let peakFootprintBytes: Int?
    let micOffsetSeconds: Double?
}

private struct DistanceSummary: Encodable {
    let count: Int
    let minimum: Double?
    let p5: Double?
    let p50: Double?
    let p95: Double?
    let maximum: Double?
}

private struct CalibrationReport: Encodable {
    let pairs: [String]
    /// Cosine distances between the centroids of clusters mapped to the same named Otter label in both files.
    let samePerson: DistanceSummary
    /// … and to different named labels.
    let differentPerson: DistanceSummary
    /// The smallest distance with at most 5 % of the different-person pairs strictly below it (§4.10).
    let possibleMaxDistance: Double?
    let samePersonAtOrBelowPossible: Int
    /// Mapped clusters left out because their Otter label names nobody ("Speaker 2").
    let genericLabelsExcluded: Int
}

private struct SpeakerReport: Encodable {
    let schemaVersion = 1
    let locale: String
    let backend: String
    let referenceProvenance: String
    let collar: Double
    let imports: [ImportRow]
    let rows: [SpeakerRow]
    let calibration: CalibrationReport?
}

/// Runs `executable` with stdout and stderr going to files in `scratch` (no pipe can fill up and stall it) and
/// returns what it wrote; the files are removed. Past `timeout` the process gets SIGTERM (which makes
/// `holos session import` remove its partial session), then SIGKILL after 10 s.
private func runCommand(_ executable: URL, _ arguments: [String], timeout: Double, scratch: URL,
                        what: String) throws -> CommandResult {
    let manager = FileManager.default
    let token = UUID().uuidString
    let outURL = scratch.appendingPathComponent(".stdout-\(token)")
    let errURL = scratch.appendingPathComponent(".stderr-\(token)")
    defer {
        try? manager.removeItem(at: outURL)
        try? manager.removeItem(at: errURL)
    }
    guard manager.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
          manager.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw EvaluationError.message("Cannot create the command output files in the run directory.")
    }
    let out = try FileHandle(forWritingTo: outURL)
    let err = try FileHandle(forWritingTo: errURL)
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = out
    process.standardError = err
    let started = ProcessInfo.processInfo.systemUptime
    try process.run()
    while process.isRunning {
        if ProcessInfo.processInfo.systemUptime - started > timeout {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime
            while process.isRunning, ProcessInfo.processInfo.systemUptime - grace < 10 {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? out.close()
            try? err.close()
            throw EvaluationError.message("\(what) timed out after \(Int(timeout)) s.")
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    process.waitUntilExit()
    let seconds = ProcessInfo.processInfo.systemUptime - started
    try out.close()
    try err.close()
    guard process.terminationReason == .exit else {
        throw EvaluationError.message("\(what) was ended by signal \(process.terminationStatus).")
    }
    return CommandResult(status: process.terminationStatus, stdout: try Data(contentsOf: outURL),
                         stderr: try Data(contentsOf: errURL), seconds: seconds)
}

/// A number `/usr/bin/time -l` printed on its own line before `name` ("maximum resident set size").
private func timeMetric(_ output: Data, _ name: String) -> Int? {
    for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(name) else { continue }
        if let value = Int(trimmed.prefix(while: \.isNumber)) { return value }
    }
    return nil
}

/// Little-endian Float32 values from base64 (`FloatVector`'s JSON form).
private func floats(fromBase64 text: String) -> [Float]? {
    guard let data = Data(base64Encoded: text), data.count % 4 == 0 else { return nil }
    let bytes = [UInt8](data)
    return stride(from: 0, to: bytes.count, by: 4).map { index in
        Float(bitPattern: UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24)
    }
}

/// 1 − cosine similarity; 2 for mismatched, empty, or zero vectors (they never match, as in recognition).
private func cosineDistance(_ first: [Float], _ second: [Float]) -> Double {
    guard first.count == second.count, !first.isEmpty else { return 2 }
    var dot = 0.0
    var firstNorm = 0.0
    var secondNorm = 0.0
    for index in first.indices {
        let a = Double(first[index])
        let b = Double(second[index])
        dot += a * b
        firstNorm += a * a
        secondNorm += b * b
    }
    guard firstNorm > 0, secondNorm > 0 else { return 2 }
    return 1 - dot / (firstNorm.squareRoot() * secondNorm.squareRoot())
}

/// Linear interpolation between order statistics of an ascending array (numpy's default); nil when empty.
private func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
    guard !sorted.isEmpty else { return nil }
    let position = Double(sorted.count - 1) * fraction
    let lower = Int(position.rounded(.down))
    let upper = min(lower + 1, sorted.count - 1)
    return sorted[lower] + (position - Double(lower)) * (sorted[upper] - sorted[lower])
}

private func summarize(_ sorted: [Double]) -> DistanceSummary {
    DistanceSummary(count: sorted.count, minimum: sorted.first, p5: percentile(sorted, 0.05),
                    p50: percentile(sorted, 0.5), p95: percentile(sorted, 0.95), maximum: sorted.last)
}

/// The smallest distance of an ascending array with at most 5 % of the array strictly below it.
private func fivePercentFloor(_ sorted: [Double]) -> Double? {
    guard !sorted.isEmpty else { return nil }
    return sorted[min(sorted.count - 1, Int((0.05 * Double(sorted.count)).rounded(.down)))]
}

private struct CalibrationInput {
    let score: ScoreReport
    let centroids: [String: [Float]]
}

/// Cross-recording distances: every mapped, named cluster of the first file against every one of the second.
private func calibrationReport(first: CalibrationInput, second: CalibrationInput) -> CalibrationReport {
    func named(_ input: CalibrationInput) -> [(key: String, vector: [Float])] {
        input.score.mapping.keys.sorted().compactMap { key in
            guard !input.score.genericLabels.contains(key), let cluster = input.score.mapping[key],
                  let vector = input.centroids[cluster] else { return nil }
            return (key, vector)
        }
    }
    var same: [Double] = []
    var different: [Double] = []
    for a in named(first) {
        for b in named(second) {
            let distance = cosineDistance(a.vector, b.vector)
            if a.key == b.key { same.append(distance) } else { different.append(distance) }
        }
    }
    same.sort()
    different.sort()
    let possible = fivePercentFloor(different)
    let excluded = [first, second].reduce(0) { total, input in
        total + input.score.mapping.keys.filter { input.score.genericLabels.contains($0) }.count
    }
    return CalibrationReport(pairs: calibrationPairs, samePerson: summarize(same), differentPerson: summarize(different),
                             possibleMaxDistance: possible,
                             samePersonAtOrBelowPossible: possible.map { limit in same.filter { $0 <= limit }.count } ?? 0,
                             genericLabelsExcluded: excluded)
}

/// `holos session diarize --force --json` under `/usr/bin/time -l`, then `holos session score --json`.
private func labelAndScore(_ options: Options, pair: String, session: URL, reference: URL, configuration: String,
                           arguments: [String], hint: String?) throws -> (row: SpeakerRow, score: ScoreReport) {
    print("Pair \(pair): labelling speakers (\(configuration))…")
    let what = "Labelling pair \(pair) (\(configuration))"
    let diarized = try runCommand(URL(fileURLWithPath: "/usr/bin/time"),
                                  ["-l", options.cli.path, "session", "diarize", session.path, "--force", "--json"]
                                      + arguments,
                                  timeout: options.timeoutSeconds, scratch: options.output, what: what)
    let record = try? JSONDecoder().decode(DiarizeRecord.self, from: diarized.stdout)
    guard diarized.status == 0, let record, record.state == "succeeded", let runID = record.runID else {
        throw EvaluationError.message("\(what) failed: exit \(diarized.status), state \(record?.state ?? "unknown"). "
                                      + (record?.message ?? ""))
    }
    let scored = try runCommand(options.cli, ["session", "score", session.path, "--otter", reference.path, "--json"],
                                timeout: options.timeoutSeconds, scratch: options.output,
                                what: "Scoring pair \(pair) (\(configuration))")
    guard scored.status == 0, let score = try? JSONDecoder().decode(ScoreReport.self, from: scored.stdout) else {
        throw EvaluationError.message("Scoring pair \(pair) (\(configuration)) failed: exit \(scored.status).")
    }
    guard score.runID == runID else {
        throw EvaluationError.message("Scoring pair \(pair) (\(configuration)) read another run than it labelled.")
    }
    let row = SpeakerRow(
        pair: pair, configuration: configuration, speakerHint: hint,
        exclusiveSegments: score.engineConfiguration["exclusiveSegments"],
        referenceSpeakers: score.referenceSpeakers, referenceSpeakersOver30s: score.referenceSpeakersOver30s,
        holosSpeakers: score.holosSpeakers, holosSpeakersOver30s: score.holosSpeakersOver30s,
        agreementConfusion: score.agreementConfusion, comparedSeconds: score.comparedSeconds,
        turnAgreementConfusion: score.turnAgreementConfusion, turnComparedSeconds: score.turnComparedSeconds,
        mappedSpeakers: score.mappingSize,
        diarizationSeconds: record.stages.last { $0.stage == "diarize" }?.seconds ?? 0,
        commandSeconds: diarized.seconds,
        peakRSSBytes: timeMetric(diarized.stderr, "maximum resident set size"),
        peakFootprintBytes: timeMetric(diarized.stderr, "peak memory footprint"),
        micOffsetSeconds: score.trackOffsets["mic"])
    return (row, score)
}

/// The centroids of the run's voice data (`--voice-data`), by cluster ID.
private func voiceCentroids(session: URL, runID: String) throws -> [String: [Float]] {
    let url = session.appendingPathComponent("speakers/voice/\(runID).json")
    let voice = try JSONDecoder().decode(VoiceData.self, from: Data(contentsOf: url))
    var centroids: [String: [Float]] = [:]
    for (cluster, text) in voice.centroids {
        guard let vector = floats(fromBase64: text) else {
            throw EvaluationError.message("The voice data of run \(runID) has a malformed centroid.")
        }
        centroids[cluster] = vector
    }
    return centroids
}

private func speakerMarkdown(_ report: SpeakerReport) -> String {
    func percent(_ value: Double) -> String { String(format: "%.1f %%", value * 100) }
    func megabytes(_ bytes: Int?) -> String { bytes.map { String(format: "%.0f", Double($0) / 1_048_576) } ?? "–" }
    func number(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "–" }
    var lines = ["# Speaker labels against Otter", "",
                 report.referenceProvenance + ". Confusion is the share of the time where both Holos and Otter "
                     + "have a speaker whose speaker differs after the best one-to-one mapping: agreement with "
                     + "Otter, not accuracy. Collar \(report.collar) s around Otter turn boundaries.",
                 "", "## Imports (\(report.backend), \(report.locale))", "",
                 "| Pair | Audio s | Import s |", "| --- | ---: | ---: |"]
    for row in report.imports {
        lines.append(String(format: "| %@ | %.1f | %.1f |", row.pair, row.audioSeconds, row.importSeconds))
    }
    lines += ["", "## Speaker labels", "",
              "| Pair | Configuration | Otter speakers (≥ 30 s) | Holos speakers (≥ 30 s) | Segment confusion | "
                  + "Compared s | Turn confusion | Turn compared s | Mapped | Diarize s | Command s | Peak RSS MB | "
                  + "Footprint MB | Mic offset s |",
              "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in report.rows {
        let configuration = row.speakerHint.map { "\(row.configuration) (\($0))" } ?? row.configuration
        lines.append("| \(row.pair) | \(configuration) | \(row.referenceSpeakers) (\(row.referenceSpeakersOver30s)) | "
            + "\(row.holosSpeakers) (\(row.holosSpeakersOver30s)) | \(percent(row.agreementConfusion)) | "
            + String(format: "%.1f", row.comparedSeconds) + " | \(percent(row.turnAgreementConfusion)) | "
            + String(format: "%.1f", row.turnComparedSeconds) + " | \(row.mappedSpeakers) | "
            + String(format: "%.1f | %.1f", row.diarizationSeconds, row.commandSeconds)
            + " | \(megabytes(row.peakRSSBytes)) | \(megabytes(row.peakFootprintBytes)) | "
            + "\(row.micOffsetSeconds.map { String(format: "%+.2f", $0) } ?? "–") |")
    }
    if let calibration = report.calibration {
        lines += ["", "## Calibration (\(calibration.pairs.joined(separator: " × ")), centroid cosine distance)", "",
                  "| Pairs | Count | Min | 5th | 50th | 95th | Max |", "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
        for (name, summary) in [("Same person", calibration.samePerson), ("Different people", calibration.differentPerson)] {
            lines.append("| \(name) | \(summary.count) | \(number(summary.minimum)) | \(number(summary.p5)) | "
                + "\(number(summary.p50)) | \(number(summary.p95)) | \(number(summary.maximum)) |")
        }
        lines += ["", "Smallest distance with at most 5 % of different-person pairs below it: "
                  + "\(number(calibration.possibleMaxDistance)); same-person pairs at or below it: "
                  + "\(calibration.samePersonAtOrBelowPossible) of \(calibration.samePerson.count). Mapped clusters "
                  + "with a generic Otter label, left out: \(calibration.genericLabelsExcluded)."]
    }
    return lines.joined(separator: "\n") + "\n"
}

/// `--speakers` and `--calibrate`: import each Otter pair once (transcribed), then label and score it per
/// configuration. Prints and writes counts, seconds, ratios, and distances only; the temporary sessions (which hold
/// the audio and a transcript) are deleted unless `--keep-sessions`.
private func evaluateSpeakers(_ options: Options) throws {
    let manager = FileManager.default
    var pairs = try pairedInputs(options)
    if !options.speakers { pairs = pairs.filter { calibrationPairs.contains($0.name) } }
    guard !pairs.isEmpty else { throw EvaluationError.message("No pairs matched the requested --pair selection.") }
    if options.calibrate, !calibrationPairs.allSatisfy({ name in pairs.contains { $0.name == name } }) {
        throw EvaluationError.message("--calibrate needs pairs \(calibrationPairs.joined(separator: " and ")).")
    }
    try manager.createDirectory(at: options.output, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    let sessions = options.output.appendingPathComponent("sessions", isDirectory: true)
    try manager.createDirectory(at: sessions, withIntermediateDirectories: false,
                                attributes: [.posixPermissions: 0o700])
    defer {
        if !options.keepSessions { try? manager.removeItem(at: sessions) }
    }
    let backend = options.backends[0]
    var imports: [ImportRow] = []
    var rows: [SpeakerRow] = []
    var calibrationInputs: [String: CalibrationInput] = [:]
    for pair in pairs {
        print("Pair \(pair.name): importing and transcribing…")
        let audio = try AVAudioFile(forReading: pair.audio)
        let audioSeconds = Double(audio.length) / audio.processingFormat.sampleRate
        let imported = try runCommand(
            options.cli, ["session", "import", pair.audio.path, "--name", "Otter \(pair.name)", "--directory",
                          sessions.path, "--locale", options.locale, "--backend", backend, "--no-postprocess"],
            timeout: options.timeoutSeconds, scratch: options.output, what: "Importing pair \(pair.name)")
        guard imported.status == 0,
              let line = String(decoding: imported.stdout, as: UTF8.self).split(separator: "\n").last else {
            throw EvaluationError.message("Importing pair \(pair.name) failed: exit \(imported.status).")
        }
        let session = URL(fileURLWithPath: line.trimmingCharacters(in: .whitespaces), isDirectory: true)
            .standardizedFileURL
        guard session.path.hasPrefix(sessions.standardizedFileURL.path + "/") else {
            throw EvaluationError.message("Importing pair \(pair.name) reported a session outside the run directory.")
        }
        imports.append(ImportRow(pair: pair.name, audioSeconds: audioSeconds, importSeconds: imported.seconds))

        let wantsVoice = options.calibrate && calibrationPairs.contains(pair.name)
        let base = try labelAndScore(options, pair: pair.name, session: session, reference: pair.reference,
                                     configuration: "default", arguments: wantsVoice ? ["--voice-data"] : [],
                                     hint: nil)
        rows.append(base.row)
        if wantsVoice {
            calibrationInputs[pair.name] = CalibrationInput(
                score: base.score, centroids: try voiceCentroids(session: session, runID: base.score.runID))
        }
        guard options.speakers else { continue }
        rows.append(try labelAndScore(options, pair: pair.name, session: session, reference: pair.reference,
                                      configuration: "exclusiveSegments",
                                      arguments: ["--exclusive-segments", "true"], hint: nil).row)
        // Speaker-count hints for n Otter labels with at least 30 s: the design's n − 1 to n + 1 (§4.7 stage 5),
        // then the stronger forms, exactly n and at least n, to see whether any recovers merged speakers.
        let expected = base.score.referenceSpeakersOver30s
        if expected > 0 {
            let minimum = max(1, expected - 1)
            let hints: [(configuration: String, arguments: [String], hint: String)] = [
                ("speakerHint", ["--min-speakers", String(minimum), "--max-speakers", String(expected + 1)],
                 "\(minimum)–\(expected + 1)"),
                ("speakerCount", ["--speakers", String(expected)], "= \(expected)"),
                ("speakerMinimum", ["--min-speakers", String(expected)], "≥ \(expected)"),
            ]
            for hint in hints {
                rows.append(try labelAndScore(options, pair: pair.name, session: session, reference: pair.reference,
                                              configuration: hint.configuration, arguments: hint.arguments,
                                              hint: hint.hint).row)
            }
        }
    }
    var calibration: CalibrationReport?
    if options.calibrate, let first = calibrationInputs[calibrationPairs[0]],
       let second = calibrationInputs[calibrationPairs[1]] {
        calibration = calibrationReport(first: first, second: second)
    }
    let report = SpeakerReport(
        locale: options.locale, backend: backend,
        referenceProvenance: "Otter-exported speaker turns (each runs from its header to the next, so it includes pauses); not verified ground truth",
        collar: scoreCollar, imports: imports, rows: rows, calibration: calibration)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: options.output.appendingPathComponent("summary.json"),
                                     options: [.withoutOverwriting])
    let markdown = speakerMarkdown(report)
    try markdown.write(to: options.output.appendingPathComponent("summary.md"), atomically: false, encoding: .utf8)
    print(markdown)
    print("Report: \(options.output.path)")
    if options.keepSessions { print("Sessions kept: \(sessions.path)") }
}

private func selfTest() throws {
    guard tokens("Café 12:30 don't") == ["café", "12", "30", "don", "t"] else {
        throw EvaluationError.message("Tokenizer self-test failed.")
    }
    let first = editCounts(reference: ["one", "two", "three"],
                           hypothesis: ["one", "four", "three", "five"])
    guard first.substitutions == 1, first.deletions == 0, first.insertions == 1 else {
        throw EvaluationError.message("Edit-count substitution/insertion self-test failed.")
    }
    let second = editCounts(reference: ["a", "b", "c"], hypothesis: ["a", "c"])
    guard second.substitutions == 0, second.deletions == 1, second.insertions == 0 else {
        throw EvaluationError.message("Edit-count deletion self-test failed.")
    }
    let sample = "Speaker A  00:05\nHello world.\n\nSpeaker B  1:02:03\nNext sentence.\n\nTranscribed by https://otter.ai\n"
    guard stripOtterMetadata(sample) == "Hello world. Next sentence." else {
        throw EvaluationError.message("Otter metadata self-test failed.")
    }
    guard percentile([1, 2, 3, 4, 5], 0.5) == 3, percentile([0, 10], 0.05) == 0.5, percentile([], 0.5) == nil,
          fivePercentFloor((1...40).map(Double.init)) == 3, fivePercentFloor([7]) == 7 else {
        throw EvaluationError.message("Percentile self-test failed.")
    }
    guard abs(cosineDistance([1, 0], [0, 1]) - 1) < 1e-12, abs(cosineDistance([2, 0], [1, 0])) < 1e-12,
          cosineDistance([0, 0], [1, 0]) == 2, cosineDistance([1], [1, 0]) == 2 else {
        throw EvaluationError.message("Cosine distance self-test failed.")
    }
    let timeOutput = Data("        1.00 real         0.50 user\n  1863483392  maximum resident set size\n".utf8)
    guard timeMetric(timeOutput, "maximum resident set size") == 1_863_483_392,
          timeMetric(timeOutput, "peak memory footprint") == nil else {
        throw EvaluationError.message("/usr/bin/time parsing self-test failed.")
    }
    // [1.0, -2.0] as little-endian Float32.
    guard floats(fromBase64: Data([0, 0, 0x80, 0x3F, 0, 0, 0, 0xC0]).base64EncodedString()) == [1, -2],
          floats(fromBase64: "AAA=") == nil else {
        throw EvaluationError.message("Centroid decoding self-test failed.")
    }
    print("Evaluation self-tests passed.")
}

do {
    if CommandLine.arguments.dropFirst() == ["--self-test"] { try selfTest() }
    else { try evaluate() }
} catch {
    fputs("Evaluation failed: \(error)\n", stderr)
    exit(1)
}
