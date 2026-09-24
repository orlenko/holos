import Foundation

/// Small vector helpers for speaker embeddings. Arithmetic runs in `Double` so 256-d sums keep their precision.
public enum VectorMath {
    /// `1 − cos(a, b)`, in 0...2. Returns 2 (never a match) when the sizes differ, either vector is empty or has
    /// zero norm, or a value is not finite.
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for index in a.indices {
            let x = Double(a[index])
            let y = Double(b[index])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return 2 }
        let distance = 1 - dot / (normA.squareRoot() * normB.squareRoot())
        guard distance.isFinite else { return 2 }
        return min(max(distance, 0), 2)
    }

    /// `v` scaled to unit L2 norm. A vector with zero or non-finite norm is returned unchanged.
    public static func normalized(_ v: [Float]) -> [Float] {
        guard let norm = norm(v), norm > 0 else { return v }
        return v.map { Float(Double($0) / norm) }
    }

    /// The weighted mean of `vectors`. Entries with a weight that is not positive and finite contribute nothing.
    /// Nil when no entry contributes, when contributing vectors differ in size or are empty, or when a
    /// resulting value is not finite.
    public static func weightedMean(_ vectors: [([Float], Double)]) -> [Float]? {
        var sums: [Double] = []
        var totalWeight = 0.0
        for (vector, weight) in vectors where weight.isFinite && weight > 0 {
            if sums.isEmpty {
                // First contributing vector; an empty one has no meaningful mean.
                guard !vector.isEmpty else { return nil }
                sums = [Double](repeating: 0, count: vector.count)
            } else if vector.count != sums.count {
                return nil
            }
            for index in vector.indices {
                sums[index] += Double(vector[index]) * weight
            }
            totalWeight += weight
        }
        guard totalWeight > 0, totalWeight.isFinite else { return nil }
        var mean: [Float] = []
        mean.reserveCapacity(sums.count)
        for sum in sums {
            let value = sum / totalWeight
            guard value.isFinite else { return nil }
            mean.append(Float(value))
        }
        return mean
    }

    /// The L2 norm, or nil when it is not finite.
    static func norm(_ v: [Float]) -> Double? {
        var sum = 0.0
        for value in v {
            let x = Double(value)
            sum += x * x
        }
        let norm = sum.squareRoot()
        return norm.isFinite ? norm : nil
    }
}
