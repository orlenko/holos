public enum SemanticChunker {
    public struct Chunk: Sendable, Equatable {
        public let index: Int
        public let offset: Int
        public let length: Int
        public let text: String
    }

    public static func chunks(_ text: String, maxUTF16Units: Int = 3_000) -> [Chunk] {
        precondition(maxUTF16Units > 0)
        let characters = Array(text)
        var positions = [Int](repeating: 0, count: characters.count + 1)
        for index in characters.indices { positions[index + 1] = positions[index] + characters[index].utf16.count }
        var result: [Chunk] = []
        var start = 0
        while start < characters.count {
            var limit = start + 1
            while limit < characters.count && positions[limit + 1] - positions[start] <= maxUTF16Units {
                limit += 1
            }
            var end = limit
            if end < characters.count {
                let minimum = start + max(1, (end - start) / 3)
                for candidate in stride(from: end, through: minimum, by: -1) {
                    if candidate >= 2 && characters[candidate - 1] == "\n" && characters[candidate - 2] == "\n" {
                        end = candidate; break
                    }
                }
                if end == limit {
                    for candidate in stride(from: end, through: minimum, by: -1) {
                        if candidate > start && ".!?".contains(characters[candidate - 1]) &&
                            (candidate == characters.count || characters[candidate].isWhitespace) {
                            end = candidate; break
                        }
                    }
                }
                if end == limit {
                    for candidate in stride(from: end, through: minimum, by: -1) {
                        if candidate > start && characters[candidate - 1].isWhitespace {
                            end = candidate; break
                        }
                    }
                }
            }
            let chunkText = String(characters[start..<end])
            result.append(Chunk(index: result.count, offset: positions[start],
                                length: positions[end] - positions[start], text: chunkText))
            start = end
        }
        return result
    }
}
