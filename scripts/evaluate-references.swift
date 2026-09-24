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

private func parseOptions() throws -> Options {
    let manager = FileManager.default
    let args = Array(CommandLine.arguments.dropFirst())
    var values: [String: String] = [:]
    var index = 0
    while index < args.count {
        let name = args[index]
        guard ["--input", "--cli", "--output", "--locale", "--backend", "--reference-format", "--pair", "--timeout-seconds"].contains(name), index + 1 < args.count else {
            throw EvaluationError.message("Usage: swift scripts/evaluate-references.swift --input DIR --cli HOLOS_BINARY [--reference-format wispr|otter] [--pair ID] [--output .local/evaluation/RUN] [--locale en-CA] [--backend both|speech|dictation] [--timeout-seconds 600]")
        }
        guard values[name] == nil else { throw EvaluationError.message("Duplicate option: \(name)") }
        values[name] = args[index + 1]
        index += 2
    }
    guard let input = values["--input"], let cli = values["--cli"] else {
        throw EvaluationError.message("Provide --input and --cli. No reference text is printed.")
    }
    let backend = values["--backend"] ?? "both"
    let backends: [String]
    switch backend {
    case "both": backends = ["speech", "dictation"]
    case "speech", "dictation": backends = [backend]
    default: throw EvaluationError.message("Backend must be both, speech, or dictation.")
    }
    let referenceFormat = values["--reference-format"] ?? "wispr"
    guard ["wispr", "otter"].contains(referenceFormat) else {
        throw EvaluationError.message("Reference format must be wispr or otter.")
    }
    guard let timeoutSeconds = Double(values["--timeout-seconds"] ?? "600"),
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
                   referenceFormat: referenceFormat, pair: values["--pair"], timeoutSeconds: timeoutSeconds)
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
    print("Evaluation self-tests passed.")
}

do {
    if CommandLine.arguments.dropFirst() == ["--self-test"] { try selfTest() }
    else { try evaluate() }
} catch {
    fputs("Evaluation failed: \(error)\n", stderr)
    exit(1)
}
