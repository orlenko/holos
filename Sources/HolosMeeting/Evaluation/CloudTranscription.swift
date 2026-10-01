import Foundation
import HolosCore

/// OpenAI's file transcription models as this tool uses them (docs/reference-evaluation.md, "Cloud reference";
/// OpenAI's speech-to-text guide and pricing page, read 2026-09-29).
public enum CloudModels {
    /// US dollars per minute of audio. gpt-transcribe is billed per minute; the gpt-4o models are billed per token and
    /// these are OpenAI's per-minute estimates for them.
    public static let pricePerMinute: [String: Double] = [
        "gpt-transcribe": 0.0045,
        "gpt-4o-transcribe": 0.006,
        "gpt-4o-mini-transcribe": 0.003,
        "gpt-4o-transcribe-diarize": 0.006,
        "whisper-1": 0.006,
    ]

    public static let defaultModel = "gpt-transcribe"
    /// The model the optional timestamp pass uses: the only one that returns word timestamps.
    public static let timestampModel = "whisper-1"

    /// gpt-transcribe takes `languages[]` and `keywords[]`; the older models take one `language`.
    public static func takesLanguageList(_ model: String) -> Bool { model == "gpt-transcribe" }
    public static func takesKeywords(_ model: String) -> Bool { model == "gpt-transcribe" }
    /// The diarizing model needs a chunking strategy for audio over 30 s and takes no prompt.
    public static func needsChunking(_ model: String) -> Bool { model.hasPrefix("gpt-4o-transcribe-diarize") }
    public static func takesPrompt(_ model: String) -> Bool { !needsChunking(model) }

    /// Estimated cost in US dollars, or nil for a model without a known price.
    public static func estimate(model: String, seconds: Double) -> Double? {
        pricePerMinute[model].map { $0 * seconds / 60 }
    }

    /// A model name that can be part of a run ID: letters, digits, "-" and "_", and not starting with the local
    /// runs' prefix ("local-"), so a cloud run's ID is never taken for a local one.
    public static func isValidName(_ model: String) -> Bool {
        !model.isEmpty && model.count <= 64 && !model.lowercased().hasPrefix(EvalLocal.idPrefix) && model.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
        }
    }
}

/// The form fields of one transcription request, besides the file. Saved with a run (no key, no headers).
public struct CloudRequestFields: Codable, Sendable, Equatable {
    public var model: String
    public var responseFormat: String
    /// ISO 639-1 codes; sent as `languages[]` to gpt-transcribe, and as `language` to other models when there is one.
    public var languages: [String]
    public var prompt: String?
    public var keywords: [String]
    public var chunkingStrategy: String?
    public var timestampGranularities: [String]

    public init(model: String, responseFormat: String = "json", languages: [String] = [], prompt: String? = nil,
                keywords: [String] = [], chunkingStrategy: String? = nil, timestampGranularities: [String] = []) {
        self.model = model; self.responseFormat = responseFormat; self.languages = languages; self.prompt = prompt
        self.keywords = keywords; self.chunkingStrategy = chunkingStrategy
        self.timestampGranularities = timestampGranularities
    }

    /// The fields in the order they are sent, as (name, value) pairs.
    public var formFields: [(String, String)] {
        var fields: [(String, String)] = [("model", model), ("response_format", responseFormat)]
        if CloudModels.takesLanguageList(model) {
            for code in languages { fields.append(("languages[]", code)) }
        } else if languages.count == 1 {
            fields.append(("language", languages[0]))
        }
        if let prompt, !prompt.isEmpty, CloudModels.takesPrompt(model) { fields.append(("prompt", prompt)) }
        if CloudModels.takesKeywords(model) {
            for keyword in keywords { fields.append(("keywords[]", keyword)) }
        }
        if let chunkingStrategy { fields.append(("chunking_strategy", chunkingStrategy)) }
        for granularity in timestampGranularities { fields.append(("timestamp_granularities[]", granularity)) }
        return fields
    }
}

/// The parts of a transcription response the evaluation uses.
public struct CloudTranscriptionResult: Codable, Sendable, Equatable {
    public struct Word: Codable, Sendable, Equatable {
        public var word: String
        public var start: Double
        public var end: Double
    }

    public var text: String
    /// Languages the model detected (gpt-transcribe), as ISO codes.
    public var languages: [String]
    /// Billed audio seconds, when the response reports them.
    public var usageSeconds: Double?
    /// Word timestamps (whisper-1 with `verbose_json`), relative to the uploaded file.
    public var words: [Word]?

    public init(text: String, languages: [String] = [], usageSeconds: Double? = nil, words: [Word]? = nil) {
        self.text = text; self.languages = languages; self.usageSeconds = usageSeconds; self.words = words
    }

    private struct Wire: Decodable {
        struct Language: Decodable { var code: String? }
        struct Usage: Decodable { var type: String?; var seconds: Double? }
        var text: String?
        var languages: [Language]?
        var usage: Usage?
        var words: [Word]?
    }

    /// Parses a `json` or `verbose_json` response body.
    public static func parse(_ data: Data) throws -> CloudTranscriptionResult {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), let text = wire.text else {
            throw HolosError.invalidInput("OpenAI's response has no transcript text.")
        }
        return CloudTranscriptionResult(text: text, languages: (wire.languages ?? []).compactMap(\.code),
                                        usageSeconds: wire.usage?.type == "duration" ? wire.usage?.seconds : nil,
                                        words: wire.words)
    }
}

/// Sends one HTTP request. `URLSessionTransport` in the tool; tests pass a fake, so they never reach the network.
public protocol CloudHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: CloudHTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HolosError.io("OpenAI's server sent a response that is not HTTP.")
        }
        return (data, http)
    }
}

/// A request OpenAI refused or that could not be sent. The message never contains the API key.
public struct CloudTranscriptionError: LocalizedError, Sendable, Equatable {
    public var status: Int?
    public var message: String
    public var errorDescription: String? { message }
}

/// Calls POST /v1/audio/transcriptions with retries (docs/reference-evaluation.md, "Cloud reference").
public struct CloudTranscriptionClient: Sendable {
    public static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    /// Attempts per request, the first included.
    public static let maxAttempts = 6

    private let apiKey: String
    private let transport: any CloudHTTPTransport
    private let sleep: @Sendable (Duration) async throws -> Void

    /// `sleep` waits between attempts; tests pass one that returns at once.
    public init(apiKey: String, transport: any CloudHTTPTransport = URLSessionTransport(),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.apiKey = apiKey; self.transport = transport; self.sleep = sleep
    }

    /// The multipart request for `audio` (an .m4a file's bytes) named `fileName`.
    public func request(fields: CloudRequestFields, audio: Data, fileName: String,
                        boundary: String = "holos-\(UUID().uuidString)") -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(fields: fields.formFields, audio: audio, fileName: fileName,
                                              boundary: boundary)
        return request
    }

    static func multipartBody(fields: [(String, String)], audio: Data, fileName: String, boundary: String) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    /// Uploads `audio` and returns the raw response body with its parsed result. Retries network failures, 408,
    /// 409, 429 (except an exhausted quota), and 5xx, up to `maxAttempts` in all, waiting 2, 4, 8, 16, 32 s (or the
    /// server's Retry-After, up to 120 s). Cancellation (Ctrl-C) stops at once with `CancellationError`.
    /// `onRetry` reports each wait.
    public func transcribe(fields: CloudRequestFields, audio: Data, fileName: String,
                           onRetry: @Sendable (_ attempt: Int, _ wait: Duration, _ reason: String) -> Void = { _, _, _ in })
        async throws -> (raw: Data, result: CloudTranscriptionResult, attempts: Int) {
        let request = request(fields: fields, audio: audio, fileName: fileName)
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let retryReason: String
            var retryAfter: Double?
            do {
                let (data, response) = try await transport.send(request)
                switch response.statusCode {
                case 200..<300:
                    return (data, try CloudTranscriptionResult.parse(data), attempt)
                case 408, 409, 429, 500...599:
                    let message = Self.errorMessage(data, status: response.statusCode)
                    if response.statusCode == 429, Self.errorCode(data) == "insufficient_quota" {
                        throw CloudTranscriptionError(status: 429, message: message)
                    }
                    retryReason = message
                    retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                default:
                    throw CloudTranscriptionError(status: response.statusCode,
                                                  message: Self.errorMessage(data, status: response.statusCode))
                }
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                retryReason = "Network error: \(Self.redacted(error.localizedDescription))"
            }
            guard attempt < Self.maxAttempts else {
                throw CloudTranscriptionError(status: nil,
                                              message: "Gave up after \(attempt) attempts: \(retryReason)")
            }
            let backoff = min(60, pow(2, Double(attempt)))
            let seconds = min(120, max(backoff, retryAfter ?? 0))
            let wait = Duration.milliseconds(Int64(seconds * 1000))
            onRetry(attempt, wait, retryReason)
            try await sleep(wait)
            attempt += 1
        }
    }

    private struct ErrorBody: Decodable {
        struct Inner: Decodable { var message: String?; var code: String? }
        var error: Inner?
    }

    static func errorCode(_ data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.code
    }

    /// A one-line reason for an error response. A refused key gets a fixed message: OpenAI's own quotes part of it.
    static func errorMessage(_ data: Data, status: Int) -> String {
        if status == 401 {
            return "OpenAI refused the API key (HTTP 401). Check OPENAI_API_KEY."
        }
        let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.message
            .map { String($0.prefix(300)) }
        return "OpenAI answered HTTP \(status)" + (detail.map { ": \(redacted($0))" } ?? ".")
    }

    /// `text` with anything that looks like an OpenAI key ("sk-…") replaced.
    public static func redacted(_ text: String) -> String {
        text.replacing(/sk-[A-Za-z0-9_\-*]{4,}/, with: "sk-…")
    }
}
