import Foundation
import HolosCore
import llama
import Synchronization

/// A GGUF language model loaded with llama.cpp on the GPU, and one context for it (docs/design.md "Tidy Up"). Greedy
/// decoding; each `generate` starts from an empty context.
///
/// Invariants:
/// 1. The C handles are used only on `queue`, one call at a time, and freed once, in `deinit`.
/// 2. `generate` returns only text the model finished (an end-of-generation token or `maxTokens`); a cancelled or
///    failed call throws.
public final class LlamaModel: @unchecked Sendable {
    // @unchecked Sendable: the C handles below are touched only on `queue` (invariant 1).
    private let queue = DispatchQueue(label: "ca.orlenko.holos.llama")
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    public let contextTokens: Int

    public enum Failure: Error, Equatable {
        case load(String)
        case tooLong(tokens: Int, context: Int)
        case decode(Int32)
    }

    /// Loads `file` with every layer on the GPU and a context of `contextTokens`. llama.cpp's own log stays quiet.
    public init(file: URL, contextTokens: Int = 16384) throws {
        Self.backend
        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(file.path, modelParameters) else {
            throw Failure.load("llama.cpp could not load \(file.lastPathComponent)")
        }
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(contextTokens)
        contextParameters.n_batch = 2048
        guard let context = llama_init_from_model(model, contextParameters) else {
            llama_model_free(model)
            throw Failure.load("llama.cpp could not make a context for \(file.lastPathComponent)")
        }
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.contextTokens = contextTokens
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// Initializes llama.cpp's backends once per process and silences its log.
    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    /// A prompt in the model's chat format: `before` and `after`, whose special tokens (`<|im_start|>`) are parsed as
    /// such, around `content`, the person's text, which is tokenized without them (a `<|im_end|>` typed in it stays
    /// text; tokens llama.cpp always matches, such as Qwen's `<think>`, do not).
    public struct Prompt: Sendable {
        public var before: String
        public var content: String
        public var after: String
        public init(before: String, content: String, after: String) {
            self.before = before; self.content = content; self.after = after
        }
    }

    /// The model's reply to `prompt`, at most `maxTokens(contentTokens)` tokens, where `contentTokens` is the number of
    /// tokens in `prompt.content`. Throws `Failure.tooLong` when the prompt and that many tokens do not fit the
    /// context, and `CancellationError` when the task is cancelled; the decoding stops at the next token.
    public func generate(_ prompt: Prompt, maxTokens: @escaping @Sendable (Int) -> Int) async throws -> String {
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(with: Result {
                        try run(prompt: prompt, maxTokens: maxTokens, cancelled: cancelled)
                    })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// On `queue` (invariant 1).
    private func run(prompt: Prompt, maxTokens: (Int) -> Int, cancelled: borrowing Mutex<Bool>) throws -> String {
        llama_memory_clear(llama_get_memory(context), true)
        let content = tokenize(prompt.content, special: false)
        var tokens = tokenize(prompt.before, special: true) + content + tokenize(prompt.after, special: true)
        let maxTokens = maxTokens(content.count)
        guard tokens.count + maxTokens <= contextTokens else {
            throw Failure.tooLong(tokens: tokens.count + maxTokens, context: contextTokens)
        }
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var start = 0
        while start < tokens.count {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            let count = min(2048, tokens.count - start)
            let status = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress! + start, Int32(count)))
            }
            guard status == 0 else { throw Failure.decode(status) }
            start += count
        }
        var reply = Data()
        for _ in 0 ..< maxTokens {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            reply.append(piece(token))
            let status = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
            guard status == 0 else { throw Failure.decode(status) }
        }
        return String(decoding: reply, as: UTF8.self)
    }

    /// `text`'s tokens, with special tokens (`<|im_start|>`) parsed as such only when `special`; no beginning-of-text
    /// token is added.
    func tokenize(_ text: String, special: Bool) -> [llama_token] {
        guard !text.isEmpty else { return [] }
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        var count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), false, special)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), false, special)
        }
        return Array(tokens.prefix(Int(max(0, count))))
    }

    /// The bytes of `token` (a piece may be part of a UTF-8 character; the reply is decoded once complete).
    private func piece(_ token: llama_token) -> Data {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return Data(buffer.prefix(Int(max(0, count))).map { UInt8(bitPattern: $0) })
    }
}
