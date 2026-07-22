import BigInt

/// Exact Fibonacci computation through binary exponentiation in scaled ℤ[√5] coordinates.
public enum FibonacciEngine {
    /// Returns `F(index)` with no recurrence cache or reuse from neighboring indices.
    ///
    /// The exponentiation performs Θ(log n) ring operations. Large coefficient products
    /// are delegated to `FFTMultiplier`, which retains an exact `BigInt` fallback.
    public nonisolated static func value(at index: UInt64) -> BigInt {
        if index == 0 { return 0 }
        if index <= 2 { return 1 }

        var step = Zrt5(1, 1)
        var result = Zrt5(1, 1)
        var exponent = index - 1

        while exponent > 0 {
            if !exponent.isMultiple(of: 2) {
                result = result.multiply(step)
                result.rightShift(1)
            }

            exponent >>= 1
            guard exponent > 0 else { break }

            step = step.square()
            step.rightShift(1)
        }

        return result.b
    }
}
