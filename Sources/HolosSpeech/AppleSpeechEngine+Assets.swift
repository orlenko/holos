import HolosCore

extension AppleSpeechEngine {
    /// A failed readiness check is unknown, not proof that the configured language is unsupported.
    public static func assetStatusOrUnknown(locale: String, backend: SpeechBackend) async -> String {
        (try? await assetStatus(locale: locale, backend: backend)) ?? "unknown"
    }

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
