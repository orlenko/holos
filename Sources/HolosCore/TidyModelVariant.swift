import Foundation

extension TidyModel {
    /// Downloadable choices in Tidy Up. The original 9B model keeps its existing paths.
    public enum Variant: String, Sendable, CaseIterable {
        case qwen
        case qwen4b
        case s1Mini = "s1-mini"
        case muesli

        public var displayName: String {
            switch self {
            case .qwen: TidyModel.displayName
            case .qwen4b: "Qwen3.5 4B"
            case .s1Mini: "S1-mini by Superwhisper"
            case .muesli: "Muesli Qwen3.5 2B"
            }
        }

        public var downloadSize: String {
            switch self {
            case .qwen: "5.7 GB"
            case .qwen4b: "2.7 GB"
            case .s1Mini: "484 MB"
            case .muesli: "1.3 GB"
            }
        }

        public var englishOnly: Bool { self == .s1Mini || self == .muesli }
        public var fileName: String { artifact.file }
        public var size: Int64 { artifact.bytes }
        public var sha256: String { artifact.digest }

        public var downloadURL: URL {
            let pin = artifact
            return URL(string: "https://huggingface.co/\(pin.repository)/resolve/\(pin.revision)/\(pin.file)")!
        }

        public func directory(in root: URL = TidyModel.root) -> URL {
            self == .qwen ? root : root.appendingPathComponent(rawValue, isDirectory: true)
        }

        public func file(in root: URL = TidyModel.root) -> URL {
            directory(in: root).appendingPathComponent(fileName)
        }

        public func status(in root: URL = TidyModel.root) -> DeepModelStatus {
            if let size = (try? FileManager.default.attributesOfItem(atPath: file(in: root).path))?[.size] as? Int64,
               size == self.size {
                return .installed
            }
            return TidyModel.lockIsHeld(root: directory(in: root)) ? .downloading : .notInstalled
        }

        private var artifact: (repository: String, revision: String, file: String, bytes: Int64, digest: String) {
            switch self {
            case .qwen:
                (TidyModel.repository, TidyModel.revision, TidyModel.fileName, TidyModel.size, TidyModel.sha256)
            case .qwen4b:
                ("unsloth/Qwen3.5-4B-GGUF", "e87f176479d0855a907a41277aca2f8ee7a09523", "Qwen3.5-4B-Q4_K_M.gguf",
                 2_740_937_888, "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4")
            case .s1Mini:
                ("superwhisper/s1-mini-GGUF", "34add00a48a2e5d24e5a4ee5405a99620a3a240c", "s1-mini-q4_k_m.gguf",
                 484_219_808, "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634")
            case .muesli:
                ("Muesli-HQ/qwen35-2b-muesli-cleanup-v12-gguf", "e35af097be4f17d3673515fb321ce19aa300faf6",
                 "qwen35-2b-muesli-v12-Q4_K_M.gguf", 1_274_396_096,
                 "2d59d2118170e0170fa294d71eba0a701c4f26063f284f68a8bed880322c4143")
            }
        }
    }
}
