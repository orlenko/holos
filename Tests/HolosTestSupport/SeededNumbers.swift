/// Deterministic pseudo-random numbers in [0, 1) (64-bit LCG), so a property test is reproducible.
public struct SeededNumbers: Sendable {
    public var state: UInt64

    public init(state: UInt64) { self.state = state }

    public mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }

    public mutating func pick<T>(_ items: [T]) -> T {
        items[min(Int(next() * Double(items.count)), items.count - 1)]
    }
}

/// A small deterministic generator (SplitMix64), for noise and integers, so failures reproduce.
public struct SplitMix64: Sendable {
    public var state: UInt64

    public init(state: UInt64) { self.state = state }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    /// Uniform in [−1, 1).
    public mutating func uniform() -> Float { Float(Double(next() >> 11) / Double(1 << 52)) - 1 }
}
