import HolosCore

extension AppleSpeechEngine {
    /// Bounds platform asset requests while preserving their errors. Late completion publishes no caller state.
    static func boundedAssetCall<Value: Sendable>(timeout: Duration,
                                                 operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let outcome = await TranscriptFixer.firstOf(timeout) {
            do { return Result<Value, Error>.success(try await operation()) }
            catch { return Result<Value, Error>.failure(error) }
        }
        try Task.checkCancellation()
        switch outcome {
        case .value(let result): return try result.get()
        case .timedOut: throw HolosError.unavailable("Speech model request timed out. Try again.")
        case .failed: throw CancellationError()
        }
    }
}
