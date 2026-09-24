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

/// Blocks the calling thread for good: another thread is ending the process.
private func park() -> Never {
    while true { sleep(3600) }
}

/// The one way this script exits. It tracks the private temporary paths (sessions holding audio and transcripts,
/// captured command output) and the process group of the command running now, so SIGINT, SIGTERM, and SIGHUP end
/// that group and remove those paths before the evaluator exits with 128 + the signal, as a `defer` cannot when a
/// signal ends the process.
private final class Termination: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGroup: pid_t?
    private var pending: Int32?
    private var exiting = false
    private var privatePaths: [URL] = []

    /// The first termination signal received, if any.
    var pendingSignal: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    /// Runs `create` (which makes `url`) and removes `url` on any exit until `release`. Parks when the process is
    /// already ending, so nothing private is created after the cleanup ran.
    func createPrivate(_ url: URL, _ create: () throws -> Void) throws {
        lock.lock()
        if exiting || pending != nil { lock.unlock(); park() }
        defer { lock.unlock() }
        privatePaths.append(url)
        do { try create() } catch {
            privatePaths.removeLast()
            throw error
        }
    }

    /// Stops removing `url` at exit (the caller removed it, or keeps it).
    func release(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        privatePaths.removeAll { $0 == url }
    }

    /// Spawns (`spawn` returns the new group's leader) and records the group as the one a signal is forwarded to.
    /// The lock is held across the spawn, so a signal cannot slip between the spawn and the record.
    func startGroup(_ spawn: () throws -> pid_t) throws -> pid_t {
        lock.lock()
        if exiting || pending != nil { lock.unlock(); park() }
        defer { lock.unlock() }
        let pid = try spawn()
        activeGroup = pid
        return pid
    }

    /// The group's leader was reaped. Returns the signal received meanwhile, if any: the group stays the one later
    /// signals go to, as the caller still ends the rest of it and then exits.
    func groupEnded() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        if pending == nil { activeGroup = nil }
        return pending
    }

    /// A signal handler: forwards the signal to the running group (whose waiter ends it and then exits), or exits
    /// now when no command runs.
    func received(_ signal: Int32) {
        lock.lock()
        if exiting { lock.unlock(); return }
        if pending == nil { pending = signal }
        if let group = activeGroup {
            _ = kill(-group, signal)
            lock.unlock()
            return
        }
        lock.unlock()
        exit(128 + signal, message: "Evaluation stopped by signal \(signal).")
    }

    /// Removes the private paths and exits. A second caller parks while the first one exits.
    func exit(_ status: Int32, message: String? = nil) -> Never {
        lock.lock()
        if exiting { lock.unlock(); park() }
        exiting = true
        for url in privatePaths.reversed() { try? FileManager.default.removeItem(at: url) }
        privatePaths.removeAll()
        if let message { fputs(message + "\n", stderr) }
        // The lock stays held: any other thread that reaches it parks until the process is gone.
        Darwin.exit(status)
    }
}

private let termination = Termination()
private let signalQueue = DispatchQueue(label: "evaluate-references.signals")
/// The handlers, installed before anything else runs. The default actions are ignored (a DispatchSourceSignal still
/// sees the signal), so the evaluator ends only through `Termination.exit`. SIGPIPE too, so printing into a closed
/// pipe fails quietly instead of ending the process with private data left behind. Commands start with the default
/// actions again (POSIX_SPAWN_SETSIGDEF).
private let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM, SIGHUP].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler { termination.received(number) }
    source.resume()
    return source
}
private let ignoresBrokenPipes: Void = { _ = signal(SIGPIPE, SIG_IGN) }()

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
    let result = try runInProcessGroup(options.cli, ["transcribe", audio.path, "--locale", options.locale,
                                                     "--backend", backend, "--output", output.path],
                                       stdout: nil, stderr: nil, timeout: options.timeoutSeconds, grace: 0.5)
    if result.timedOut {
        throw EvaluationError.message("CLI transcription timed out for \(audio.lastPathComponent) using \(backend).")
    }
    guard result.signal == nil, result.status == 0 else {
        throw EvaluationError.message("CLI transcription failed for \(audio.lastPathComponent) using \(backend) (status \(result.signal ?? result.status)).")
    }
    return result.seconds
}

/// How a command run by `runInProcessGroup` ended.
private struct GroupExit {
    /// The exit status, when it exited.
    var status: Int32
    /// The signal that ended it, when one did.
    var signal: Int32?
    var timedOut: Bool
    var seconds: Double
}

/// Runs `executable` in a new process group of its own (posix_spawn with POSIX_SPAWN_SETPGROUP), with stdin from
/// /dev/null and stdout and stderr on the given descriptors (nil: /dev/null), and waits for it. Past `timeout` the
/// whole group gets SIGTERM, and whatever of it is still running after `grace` seconds gets SIGKILL, so a wrapper
/// such as `/usr/bin/time` cannot leave its child running when it is itself ended. When the evaluator gets SIGINT,
/// SIGTERM, or SIGHUP meanwhile, the group gets the same signal (from the handler), the same SIGKILL after `grace`,
/// and the evaluator then exits through `Termination.exit` (removing the private paths) instead of returning.
/// `poll` runs every 50 ms while the command runs.
private func runInProcessGroup(_ executable: URL, _ arguments: [String], stdout: Int32?, stderr: Int32?,
                               timeout: Double, grace: Double, poll: () -> Void = {}) throws -> GroupExit {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    if let stdout { posix_spawn_file_actions_adddup2(&actions, stdout, 1) }
    else { posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) }
    if let stderr { posix_spawn_file_actions_adddup2(&actions, stderr, 2) }
    else { posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Its own group (pgid = its pid); only descriptors 0-2 are inherited; default signal handling, nothing blocked.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    posix_spawnattr_setpgroup(&attributes, 0)
    var all = sigset_t()
    sigfillset(&all)
    posix_spawnattr_setsigdefault(&attributes, &all)
    var none = sigset_t()
    sigemptyset(&none)
    posix_spawnattr_setsigmask(&attributes, &none)
    let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    let started = ProcessInfo.processInfo.systemUptime
    let pid = try termination.startGroup {
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        guard code == 0 else {
            throw EvaluationError.message("Cannot run \(executable.lastPathComponent): \(String(cString: strerror(code))).")
        }
        return pid
    }
    var status: Int32 = 0
    var reaped = false
    /// Reaps the child if it has ended (blocking when `wait`), retrying after a signal interrupts the call.
    func reap(wait: Bool) {
        guard !reaped else { return }
        while true {
            let result = waitpid(pid, &status, wait ? 0 : WNOHANG)
            if result == pid { reaped = true; return }
            if result < 0, errno == EINTR { continue }
            return
        }
    }
    func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
    /// Whether any process of the group is left (the unreaped child counts).
    func groupAlive() -> Bool { kill(-pid, 0) == 0 || errno == EPERM }
    /// Sends `signal` to the group (nil: the signal handler already did), SIGKILL to whatever of it is left after
    /// `grace`, and waits for the leader and (briefly) the rest.
    func endGroup(sending signal: Int32?) {
        if let signal { _ = kill(-pid, signal) }
        let graceStarted = uptime()
        while uptime() - graceStarted < grace {
            reap(wait: false)
            if reaped, !groupAlive() { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if !reaped || groupAlive() { _ = kill(-pid, SIGKILL) }
        reap(wait: true)
        // The rest of the group was reparented; wait (briefly) until it is gone.
        let killed = uptime()
        while groupAlive(), uptime() - killed < 5 { Thread.sleep(forTimeInterval: 0.02) }
    }
    func exitAfter(_ signal: Int32) -> Never {
        endGroup(sending: nil)
        termination.exit(128 + signal, message: "Evaluation stopped by signal \(signal); its command was ended.")
    }
    var timedOut = false
    while true {
        if let signal = termination.pendingSignal { exitAfter(signal) }
        reap(wait: false)
        if reaped { break }
        if uptime() - started > timeout {
            timedOut = true
            endGroup(sending: SIGTERM)
            break
        }
        poll()
        Thread.sleep(forTimeInterval: 0.05)
    }
    // A signal that came after the last check was forwarded to the group; end what is left of it, then exit.
    if let signal = termination.groupEnded() { exitAfter(signal) }
    let seconds = uptime() - started
    let signal = status & 0x7f
    return GroupExit(status: (status >> 8) & 0xff, signal: signal == 0 ? nil : signal, timedOut: timedOut,
                     seconds: seconds)
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
    /// Absent when no labelled turn overlaps Otter's turns (not comparable).
    let turnAgreementConfusion: Double?
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
    /// Agreement with Otter over the labelled turns; nil when not comparable.
    let turnAgreementConfusion: Double?
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
    /// A threshold with at most 5 % of the different-person pairs at or below it, for `distance ≤ threshold` (§4.10).
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
/// returns what it wrote; the files are removed. It runs in a process group of its own, so past `timeout` the
/// whole group (Holos too when `executable` is `/usr/bin/time`) gets SIGTERM (which makes `holos session import`
/// remove its partial session), then SIGKILL after 10 s.
private func runCommand(_ executable: URL, _ arguments: [String], timeout: Double, scratch: URL,
                        what: String) throws -> CommandResult {
    let manager = FileManager.default
    let token = UUID().uuidString
    let outURL = scratch.appendingPathComponent(".stdout-\(token)")
    let errURL = scratch.appendingPathComponent(".stderr-\(token)")
    defer {
        for url in [outURL, errURL] {
            try? manager.removeItem(at: url)
            termination.release(url)
        }
    }
    for url in [outURL, errURL] {
        try termination.createPrivate(url) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw EvaluationError.message("Cannot create the command output files in the run directory.")
            }
        }
    }
    let out = try FileHandle(forWritingTo: outURL)
    let err = try FileHandle(forWritingTo: errURL)
    let result: GroupExit
    do {
        defer {
            try? out.close()
            try? err.close()
        }
        result = try runInProcessGroup(executable, arguments, stdout: out.fileDescriptor,
                                       stderr: err.fileDescriptor, timeout: timeout, grace: 10)
    }
    if result.timedOut { throw EvaluationError.message("\(what) timed out after \(Int(timeout)) s.") }
    if let signal = result.signal { throw EvaluationError.message("\(what) was ended by signal \(signal).") }
    return CommandResult(status: result.status, stdout: try Data(contentsOf: outURL),
                         stderr: try Data(contentsOf: errURL), seconds: result.seconds)
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

/// A threshold t for an inclusive comparison (distance ≤ t, as §4.10 compares) that admits at most 5 % of an
/// ascending array, floor(0.05 · n) values: halfway between the largest value it admits and the first one it must
/// keep out, or just below the smallest value when it may admit none. Values tied with the first one kept out are
/// kept out too. Nil when empty.
private func fivePercentThreshold(_ sorted: [Double]) -> Double? {
    guard !sorted.isEmpty else { return nil }
    let allowed = Int((0.05 * Double(sorted.count)).rounded(.down))
    let keptOut = sorted[allowed]
    guard let admitted = sorted[..<allowed].last(where: { $0 < keptOut }) else { return keptOut.nextDown }
    return (admitted + keptOut) / 2
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
    let possible = fivePercentThreshold(different)
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
            + String(format: "%.1f", row.comparedSeconds) + " | \(row.turnAgreementConfusion.map(percent) ?? "–") | "
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
        lines += ["", "Threshold with at most 5 % of different-person pairs at or below it (compare distance ≤ it): "
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
    func createSessions() throws {
        try manager.createDirectory(at: sessions, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
    }
    // Removed on every exit, a signal included, unless --keep-sessions.
    if options.keepSessions { try createSessions() } else { try termination.createPrivate(sessions, createSessions) }
    defer {
        if !options.keepSessions {
            try? manager.removeItem(at: sessions)
            termination.release(sessions)
        }
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
          fivePercentThreshold((1...40).map(Double.init)) == 2.5, fivePercentThreshold([7]) == 7.0.nextDown,
          fivePercentThreshold([0.421, 0.444] + (1...35).map { 0.5 + Double($0) / 100 }) == (0.421 + 0.444) / 2,
          fivePercentThreshold([1, 1, 1] + (1...37).map { 1 + Double($0) }) == 1.0.nextDown else {
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
    try processGroupSelfTest()
    try signalSelfTest()
    print("Evaluation self-tests passed.")
}

/// A timed-out command under `/usr/bin/time` whose child ignores SIGTERM: `time` ends at SIGTERM, and its child
/// must still be ended (SIGKILL to the group), not left running. And a command that finishes reports its status.
private func processGroupSelfTest() throws {
    let finished = try runInProcessGroup(URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 3"], stdout: nil, stderr: nil,
                                         timeout: 30, grace: 1)
    guard !finished.timedOut, finished.signal == nil, finished.status == 3 else {
        throw EvaluationError.message("Process-group exit status self-test failed.")
    }
    let folder = try selfTestFolder()
    defer { removeSelfTestFolder(folder) }
    let pidFile = folder.appendingPathComponent("child.pid")
    let timed = try runInProcessGroup(URL(fileURLWithPath: "/usr/bin/time"),
                                      ["/bin/sh", "-c", termIgnoringChild, pidFile.path],
                                      stdout: nil, stderr: nil, timeout: 1, grace: 0.5)
    guard timed.timedOut, let child = readPID(pidFile) else {
        throw EvaluationError.message("Process-group timeout self-test did not start its child.")
    }
    guard groupGone(child) else {
        _ = kill(-child, SIGKILL)
        throw EvaluationError.message("Process-group timeout self-test left the timed child running.")
    }
}

/// A shell that ignores SIGTERM, writes its pid (atomically) to the file named by `$0`, and becomes a 60 s sleep.
private let termIgnoringChild = "trap '' TERM; echo $$ > \"$0.tmp\"; mv \"$0.tmp\" \"$0\"; exec /bin/sleep 60"
/// The hidden mode the signal self-test runs a second evaluator in.
private let signalSelfTestFlag = "--signal-self-test-child"

/// A new private temporary folder, removed on any exit.
private func selfTestFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("holos-evaluate-self-test-\(UUID().uuidString)", isDirectory: true)
    try termination.createPrivate(folder) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    return folder
}

private func removeSelfTestFolder(_ folder: URL) {
    try? FileManager.default.removeItem(at: folder)
    termination.release(folder)
}

private func readPID(_ url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
    return pid
}

/// Whether the process group led by `leader` is gone within 5 s.
private func groupGone(_ leader: pid_t) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while kill(-leader, 0) == 0 || errno == EPERM, ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    return kill(-leader, 0) != 0 && errno == ESRCH
}

/// SIGTERM to an evaluator (a second copy of this script) while its command ignores SIGTERM: the evaluator must
/// end the command's group (SIGKILL after the grace period), remove its private temporary folder, and exit 143.
private func signalSelfTest() throws {
    let folder = try selfTestFolder()
    defer { removeSelfTestFolder(folder) }
    let script = CommandLine.arguments[0]
    let executable: URL
    let arguments: [String]
    if script.hasSuffix(".swift") {
        executable = URL(fileURLWithPath: "/usr/bin/env")
        arguments = ["swift", script, signalSelfTestFlag, folder.path]
    } else if let binary = Bundle.main.executableURL {
        executable = binary
        arguments = [signalSelfTestFlag, folder.path]
    } else {
        throw EvaluationError.message("Signal self-test cannot find this evaluator's executable.")
    }
    let log = folder.appendingPathComponent("evaluator.stderr")
    guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw EvaluationError.message("Signal self-test cannot create its log.")
    }
    let logHandle = try FileHandle(forWritingTo: log)
    defer { try? logHandle.close() }
    var child: pid_t?
    // Compiling the second copy takes a while; the evaluator is signalled once its command runs.
    let run = try runInProcessGroup(executable, arguments, stdout: nil, stderr: logHandle.fileDescriptor,
                                    timeout: 300, grace: 5) {
        guard child == nil, let evaluator = readPID(folder.appendingPathComponent("evaluator.pid")),
              let started = readPID(folder.appendingPathComponent("child.pid")) else { return }
        child = started
        _ = kill(evaluator, SIGTERM)
    }
    func failure(_ text: String) -> EvaluationError {
        if let child { _ = kill(-child, SIGKILL) }
        let tail = (try? String(contentsOf: log, encoding: .utf8)).map { String($0.suffix(2000)) } ?? ""
        return EvaluationError.message("Signal self-test: \(text) \(tail)")
    }
    guard let child else { throw failure("the evaluator ended before its command started.") }
    guard !run.timedOut, run.signal == nil, run.status == 128 + SIGTERM else {
        throw failure("the evaluator did not exit 143 (status \(run.status), signal \(run.signal ?? 0)).")
    }
    guard groupGone(child) else { throw failure("the evaluator left its command's group running.") }
    guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("private").path) else {
        throw failure("the evaluator left its private folder behind.")
    }
}

/// The evaluator `signalSelfTest` signals: a private folder with a stand-in transcript, then a command that
/// ignores SIGTERM. It must never return from the command.
private func signalSelfTestChild(folder: URL) throws {
    let manager = FileManager.default
    let privateFolder = folder.appendingPathComponent("private", isDirectory: true)
    try termination.createPrivate(privateFolder) {
        try manager.createDirectory(at: privateFolder, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
    }
    try Data("stand-in transcript\n".utf8).write(to: privateFolder.appendingPathComponent("transcript.txt"))
    let pidFile = folder.appendingPathComponent("evaluator.pid")
    let pidTemporary = folder.appendingPathComponent("evaluator.pid.tmp")
    try "\(getpid())\n".write(to: pidTemporary, atomically: false, encoding: .utf8)
    try manager.moveItem(at: pidTemporary, to: pidFile)
    _ = try runInProcessGroup(URL(fileURLWithPath: "/bin/sh"),
                              ["-c", termIgnoringChild, folder.appendingPathComponent("child.pid").path],
                              stdout: nil, stderr: nil, timeout: 120, grace: 0.5)
    throw EvaluationError.message("The signal self-test's command ended without the evaluator being signalled.")
}

_ = signalSources
_ = ignoresBrokenPipes
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--self-test"] { try selfTest() }
    else if arguments.count == 2, arguments[0] == signalSelfTestFlag {
        try signalSelfTestChild(folder: URL(fileURLWithPath: arguments[1], isDirectory: true))
    } else { try evaluate() }
} catch {
    termination.exit(1, message: "Evaluation failed: \(error)")
}
termination.exit(0)
