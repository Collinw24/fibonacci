//
//  NTTMultiplier.swift
//  fibonacci
//
//  Number Theoretic Transform for exact integer multiplication
//  O(n log n) with no floating-point precision loss
//
//  Uses multi-prime NTT with Chinese Remainder Theorem reconstruction
//  Primes: 998244353, 167772161, 469762049 (all have primitive root 3)
//

import Foundation
import BigInt

enum NTTMultiplier {

    // MARK: - NTT Primes

    // Three NTT-friendly primes of form k × 2^m + 1
    // 998244353 = 119 × 2^23 + 1, supports transforms up to 2^23
    // 167772161 = 5 × 2^25 + 1, supports transforms up to 2^25
    // 469762049 = 7 × 2^26 + 1, supports transforms up to 2^26
    // All have primitive root g = 3

    nonisolated private static let primes: [UInt64] = [998244353, 167772161, 469762049]
    nonisolated private static let primitiveRoot: UInt64 = 3
    nonisolated private static let maxLog2n: [Int] = [23, 25, 26]

    // Product of primes for CRT: ~7.8 × 10^25 (fits in ~86 bits)
    // This means we can handle convolution sums up to this value

    // Base for digit representation (must be small enough that digit^2 × n < smallest prime)
    // Using base 2^15 = 32768, max n = 2^23, digit^2 × n < 2^53 < 998244353 × some factor
    // Actually for safety: base^2 × n should not overflow intermediate results
    // With base 2^12 = 4096, digit^2 = 2^24, times n = 2^23 gives 2^47 which is safe
    nonisolated private static let digitBase: UInt64 = 4096
    nonisolated private static let digitBits: Int = 12
    nonisolated private static let digitMask: UInt64 = 4095

    // Maximum transform size (limited by smallest prime's 2-adic order)
    nonisolated private static let maxTransformSize = 1 << 23

    // MARK: - Montgomery Arithmetic

    // Montgomery representation: x̄ = x × R mod N where R = 2^64
    // Multiplication: x̄ × ȳ × R^(-1) mod N gives xy in Montgomery form

    private struct MontgomeryParams {
        let prime: UInt64
        let r2: UInt64        // R^2 mod N for conversion to Montgomery form
        let nPrime: UInt64    // -N^(-1) mod R for Montgomery reduction

        init(prime: UInt64) {
            self.prime = prime

            // Compute R^2 mod N where R = 2^64
            // R mod N = 2^64 mod N
            let r: UInt64 = UInt64.max % prime + 1  // 2^64 mod N
            // R^2 mod N
            self.r2 = Self.mulmod(r, r, prime)

            // Compute -N^(-1) mod R using extended Euclidean algorithm
            // We need nPrime such that N × nPrime ≡ -1 (mod 2^64)
            self.nPrime = Self.computeNPrime(prime)
        }

        private static func mulmod(_ a: UInt64, _ b: UInt64, _ m: UInt64) -> UInt64 {
            let (hi, lo) = a.multipliedFullWidth(by: b)
            let (_, remainder) = m.dividingFullWidth((hi, lo))
            return remainder
        }

        private static func computeNPrime(_ n: UInt64) -> UInt64 {
            // Newton's method to find -n^(-1) mod 2^64
            // Start with n^(-1) mod 2^4
            var x: UInt64 = n
            // Hensel lifting: x = x * (2 - n * x) mod 2^k doubles the precision
            for _ in 0..<6 {  // 4, 8, 16, 32, 64
                x = x &* (2 &- n &* x)
            }
            return 0 &- x  // Return -n^(-1)
        }
    }

    nonisolated private static let montgomeryParams: [MontgomeryParams] = primes.map { MontgomeryParams(prime: $0) }

    // Montgomery reduction: given T < N × R, compute T × R^(-1) mod N
    @inline(__always)
    nonisolated private static func montgomeryReduce(_ t: (high: UInt64, low: UInt64), _ params: MontgomeryParams) -> UInt64 {
        // m = (T mod R) × N' mod R
        let m = t.low &* params.nPrime
        // t = (T + m × N) / R
        let (hi, _) = m.multipliedFullWidth(by: params.prime)
        var result = t.high &+ hi
        if t.low != 0 {
            result &+= 1
        }
        // Conditional subtraction
        if result >= params.prime {
            result &-= params.prime
        }
        return result
    }

    // Montgomery multiplication: x̄ × ȳ → xy (in Montgomery form)
    @inline(__always)
    nonisolated private static func montgomeryMul(_ a: UInt64, _ b: UInt64, _ params: MontgomeryParams) -> UInt64 {
        let (hi, lo) = a.multipliedFullWidth(by: b)
        return montgomeryReduce((hi, lo), params)
    }

    // Convert to Montgomery form: x → x × R mod N
    @inline(__always)
    nonisolated private static func toMontgomery(_ x: UInt64, _ params: MontgomeryParams) -> UInt64 {
        return montgomeryMul(x % params.prime, params.r2, params)
    }

    // Convert from Montgomery form: x̄ → x
    @inline(__always)
    nonisolated private static func fromMontgomery(_ x: UInt64, _ params: MontgomeryParams) -> UInt64 {
        return montgomeryReduce((0, x), params)
    }

    // Modular addition (assumes a, b < prime)
    @inline(__always)
    nonisolated private static func modAdd(_ a: UInt64, _ b: UInt64, _ prime: UInt64) -> UInt64 {
        let sum = a &+ b
        return sum >= prime ? sum &- prime : sum
    }

    // Modular subtraction (assumes a, b < prime)
    @inline(__always)
    nonisolated private static func modSub(_ a: UInt64, _ b: UInt64, _ prime: UInt64) -> UInt64 {
        return a >= b ? a &- b : a &+ prime &- b
    }

    // Modular exponentiation using Montgomery multiplication
    nonisolated private static func modPow(_ base: UInt64, _ exp: UInt64, _ params: MontgomeryParams) -> UInt64 {
        var result = toMontgomery(1, params)
        var b = toMontgomery(base % params.prime, params)
        var e = exp

        while e > 0 {
            if e & 1 != 0 {
                result = montgomeryMul(result, b, params)
            }
            b = montgomeryMul(b, b, params)
            e >>= 1
        }

        return fromMontgomery(result, params)
    }

    // MARK: - Root of Unity Tables

    private final class RootTable: @unchecked Sendable {
        nonisolated(unsafe) private var cache: [Int: (forward: [UInt64], inverse: [UInt64])] = [:]
        private let lock = NSLock()

        nonisolated func getRoots(log2n: Int, params: MontgomeryParams, maxLog: Int) -> (forward: [UInt64], inverse: [UInt64])? {
            lock.lock()
            defer { lock.unlock() }

            let key = Int(params.prime) ^ (log2n << 32)

            if let existing = cache[key] {
                return existing
            }

            guard log2n <= maxLog else { return nil }

            let n = 1 << log2n

            // Compute primitive n-th root of unity
            // ω = g^((p-1)/n) where g is primitive root
            let exponent = (params.prime - 1) / UInt64(n)
            let omega = modPow(primitiveRoot, exponent, params)
            let omegaInv = modPow(omega, UInt64(n - 1), params)  // ω^(-1) = ω^(n-1)

            // Build tables in Montgomery form for faster multiplication
            var forward = [UInt64](repeating: 0, count: n / 2)
            var inverse = [UInt64](repeating: 0, count: n / 2)

            var w: UInt64 = toMontgomery(1, params)
            var wInv: UInt64 = toMontgomery(1, params)
            let omegaMont = toMontgomery(omega, params)
            let omegaInvMont = toMontgomery(omegaInv, params)

            for i in 0..<(n / 2) {
                forward[i] = w
                inverse[i] = wInv
                w = montgomeryMul(w, omegaMont, params)
                wInv = montgomeryMul(wInv, omegaInvMont, params)
            }

            let result = (forward, inverse)
            cache[key] = result
            return result
        }
    }

    nonisolated private static let rootTables: [RootTable] = [RootTable(), RootTable(), RootTable()]

    // MARK: - NTT Transform

    // Cooley-Tukey decimation-in-time NTT
    nonisolated private static func nttForward(_ data: inout [UInt64], _ roots: [UInt64], _ params: MontgomeryParams) {
        let n = data.count
        guard n > 1 && (n & (n - 1)) == 0 else { return }

        let log2n = n.trailingZeroBitCount

        // Bit-reversal permutation
        for i in 0..<n {
            let j = bitReverse(i, log2n)
            if i < j {
                data.swapAt(i, j)
            }
        }

        // Convert to Montgomery form
        for i in 0..<n {
            data[i] = toMontgomery(data[i], params)
        }

        // Cooley-Tukey butterfly
        var len = 2
        var rootStep = n / 2

        while len <= n {
            let halfLen = len / 2

            for i in stride(from: 0, to: n, by: len) {
                var rootIdx = 0
                for j in 0..<halfLen {
                    let u = data[i + j]
                    let v = montgomeryMul(data[i + j + halfLen], roots[rootIdx], params)

                    data[i + j] = modAdd(u, v, params.prime)
                    data[i + j + halfLen] = modSub(u, v, params.prime)

                    rootIdx += rootStep
                }
            }

            len <<= 1
            rootStep >>= 1
        }
    }

    // Gentleman-Sande decimation-in-frequency inverse NTT
    nonisolated private static func nttInverse(_ data: inout [UInt64], _ roots: [UInt64], _ params: MontgomeryParams) {
        let n = data.count
        guard n > 1 && (n & (n - 1)) == 0 else { return }

        let log2n = n.trailingZeroBitCount

        // Note: data is already in Montgomery form from forward transform

        // Gentleman-Sande butterfly (no initial bit-reversal needed)
        var len = n
        var rootStep = 1

        while len >= 2 {
            let halfLen = len / 2

            for i in stride(from: 0, to: n, by: len) {
                var rootIdx = 0
                for j in 0..<halfLen {
                    let u = data[i + j]
                    let v = data[i + j + halfLen]

                    data[i + j] = modAdd(u, v, params.prime)
                    data[i + j + halfLen] = montgomeryMul(modSub(u, v, params.prime), roots[rootIdx], params)

                    rootIdx += rootStep
                }
            }

            len >>= 1
            rootStep <<= 1
        }

        // Bit-reversal permutation
        for i in 0..<n {
            let j = bitReverse(i, log2n)
            if i < j {
                data.swapAt(i, j)
            }
        }

        // Multiply by n^(-1) and convert from Montgomery form
        let nInv = modPow(UInt64(n), params.prime - 2, params)
        let nInvMont = toMontgomery(nInv, params)

        for i in 0..<n {
            data[i] = fromMontgomery(montgomeryMul(data[i], nInvMont, params), params)
        }
    }

    @inline(__always)
    nonisolated private static func bitReverse(_ x: Int, _ bits: Int) -> Int {
        var result = 0
        var v = x
        for _ in 0..<bits {
            result = (result << 1) | (v & 1)
            v >>= 1
        }
        return result
    }

    // MARK: - Multi-Prime NTT Convolution

    nonisolated private static func nttConvolve(_ a: [UInt64], _ b: [UInt64], fftSize n: Int, primeIdx: Int) -> [UInt64]? {
        guard n > 0 && (n & (n - 1)) == 0 else { return nil }

        let log2n = n.trailingZeroBitCount
        guard log2n <= maxLog2n[primeIdx] else { return nil }

        let params = montgomeryParams[primeIdx]

        guard let roots = rootTables[primeIdx].getRoots(log2n: log2n, params: params, maxLog: maxLog2n[primeIdx]) else {
            return nil
        }

        // Pad inputs
        var aPad = [UInt64](repeating: 0, count: n)
        var bPad = [UInt64](repeating: 0, count: n)

        for i in 0..<min(a.count, n) {
            aPad[i] = a[i] % params.prime
        }
        for i in 0..<min(b.count, n) {
            bPad[i] = b[i] % params.prime
        }

        // Forward NTT
        nttForward(&aPad, roots.forward, params)
        nttForward(&bPad, roots.forward, params)

        // Pointwise multiplication (both arrays are in Montgomery form after forward NTT)
        for i in 0..<n {
            aPad[i] = montgomeryMul(aPad[i], bPad[i], params)
        }

        // Inverse NTT
        nttInverse(&aPad, roots.inverse, params)

        return aPad
    }

    nonisolated private static func nttSquare(_ a: [UInt64], fftSize n: Int, primeIdx: Int) -> [UInt64]? {
        guard n > 0 && (n & (n - 1)) == 0 else { return nil }

        let log2n = n.trailingZeroBitCount
        guard log2n <= maxLog2n[primeIdx] else { return nil }

        let params = montgomeryParams[primeIdx]

        guard let roots = rootTables[primeIdx].getRoots(log2n: log2n, params: params, maxLog: maxLog2n[primeIdx]) else {
            return nil
        }

        var aPad = [UInt64](repeating: 0, count: n)

        for i in 0..<min(a.count, n) {
            aPad[i] = a[i] % params.prime
        }

        nttForward(&aPad, roots.forward, params)

        for i in 0..<n {
            aPad[i] = montgomeryMul(aPad[i], aPad[i], params)
        }

        nttInverse(&aPad, roots.inverse, params)

        return aPad
    }

    // MARK: - Chinese Remainder Theorem Reconstruction

    // Reconstruct a value from its residues modulo the three primes
    // Uses Garner's algorithm for efficient sequential reconstruction
    nonisolated private static func crtReconstruct(_ r0: UInt64, _ r1: UInt64, _ r2: UInt64) -> BigInt {
        let p0 = primes[0]
        let p1 = primes[1]
        let p2 = primes[2]

        // Precomputed: p0^(-1) mod p1, (p0 × p1)^(-1) mod p2
        // p0^(-1) mod p1 = 998244353^(-1) mod 167772161
        // (p0 × p1)^(-1) mod p2 = (998244353 × 167772161)^(-1) mod 469762049

        // Compute dynamically for correctness (can precompute for speed)
        let p0InvP1 = modPow(p0, p1 - 2, montgomeryParams[1])
        let p0p1 = BigInt(p0) * BigInt(p1)
        let p0p1ModP2 = UInt64((p0p1 % BigInt(p2)))
        let p0p1InvP2 = modPow(p0p1ModP2, p2 - 2, montgomeryParams[2])

        // Garner's algorithm
        // x ≡ r0 (mod p0)
        // x ≡ r1 (mod p1)
        // x ≡ r2 (mod p2)

        // v1 = (r1 - r0) × p0^(-1) mod p1
        let diff1 = r1 >= r0 ? r1 - r0 : r1 + p1 - (r0 % p1)
        let v1 = (diff1 % p1 * p0InvP1) % p1

        // x01 = r0 + v1 × p0 (value mod p0×p1)
        let x01 = BigInt(r0) + BigInt(v1) * BigInt(p0)

        // v2 = (r2 - x01) × (p0×p1)^(-1) mod p2
        let x01ModP2 = UInt64((x01 % BigInt(p2)))
        let diff2 = r2 >= x01ModP2 ? r2 - x01ModP2 : r2 + p2 - x01ModP2
        let v2 = (diff2 % p2 * p0p1InvP2) % p2

        // x = x01 + v2 × p0 × p1
        let result = x01 + BigInt(v2) * p0p1

        return result
    }

    // MARK: - Digit Conversion

    nonisolated private static func magnitudeToDigits(_ mag: BigUInt) -> [UInt64] {
        if mag == 0 { return [0] }

        let words = mag.words
        let totalBits = mag.bitWidth
        let digitCount = (totalBits + digitBits - 1) / digitBits

        var digits = [UInt64]()
        digits.reserveCapacity(digitCount)

        var bitPosition = 0
        var wordIndex = 0
        var currentWord: UInt64 = words.count > 0 ? UInt64(words[0]) : 0
        var bitsRemainingInWord = 64

        while bitPosition < totalBits {
            var digit: UInt64 = 0
            var bitsNeeded = digitBits
            var bitsCollected = 0

            while bitsNeeded > 0 && wordIndex < words.count {
                if bitsRemainingInWord == 0 {
                    wordIndex += 1
                    if wordIndex < words.count {
                        currentWord = UInt64(words[wordIndex])
                        bitsRemainingInWord = 64
                    } else {
                        break
                    }
                }

                let bitsToTake = min(bitsNeeded, bitsRemainingInWord)
                let mask = (UInt64(1) << bitsToTake) - 1
                let bits = currentWord & mask

                digit |= bits << bitsCollected

                currentWord >>= bitsToTake
                bitsRemainingInWord -= bitsToTake
                bitsNeeded -= bitsToTake
                bitsCollected += bitsToTake
            }

            digits.append(digit & digitMask)
            bitPosition += digitBits
        }

        return digits
    }

    nonisolated private static func digitsToMagnitude(_ digits: [BigInt]) -> BigInt {
        if digits.isEmpty { return BigInt(0) }

        var words: [UInt] = []
        let estimatedWords = (digits.count * digitBits + 63) / 64
        words.reserveCapacity(estimatedWords)

        var accumulator: UInt = 0
        var bitsInAccumulator = 0

        for digit in digits {
            let d = UInt(digit.magnitude.words.first ?? 0)
            accumulator |= d << bitsInAccumulator
            bitsInAccumulator += digitBits

            while bitsInAccumulator >= 64 {
                words.append(accumulator)
                accumulator = d >> (digitBits - (bitsInAccumulator - 64))
                bitsInAccumulator -= 64
            }
        }

        if bitsInAccumulator > 0 || words.isEmpty {
            words.append(accumulator)
        }

        while words.count > 1 && words.last == 0 {
            words.removeLast()
        }

        return BigInt(sign: .plus, magnitude: BigUInt(words: words))
    }

    // MARK: - Public Interface

    nonisolated static func multiply(_ a: BigInt, _ b: BigInt) -> BigInt {
        if a == 0 || b == 0 { return BigInt(0) }

        let aMag = a.magnitude
        let bMag = b.magnitude
        let combinedBits = aMag.bitWidth + bMag.bitWidth

        // Fall back to standard multiplication for small numbers
        if combinedBits < 8000 {
            return a * b
        }

        let aDigits = magnitudeToDigits(aMag)
        let bDigits = magnitudeToDigits(bMag)

        let n = nextPowerOf2(aDigits.count + bDigits.count)

        if n > maxTransformSize {
            // Fall back to FFT for very large numbers beyond NTT capacity
            return a * b
        }

        // Perform NTT convolution with all three primes
        guard let r0 = nttConvolve(aDigits, bDigits, fftSize: n, primeIdx: 0),
              let r1 = nttConvolve(aDigits, bDigits, fftSize: n, primeIdx: 1),
              let r2 = nttConvolve(aDigits, bDigits, fftSize: n, primeIdx: 2) else {
            return a * b
        }

        // CRT reconstruction and carry propagation
        var resultDigits = [BigInt](repeating: BigInt(0), count: n + 64)
        var carry = BigInt(0)

        let base = BigInt(digitBase)

        for i in 0..<n {
            let reconstructed = crtReconstruct(r0[i], r1[i], r2[i])
            let total = reconstructed + carry

            let (q, r) = total.quotientAndRemainder(dividingBy: base)
            resultDigits[i] = r
            carry = q
        }

        var idx = n
        while carry > 0 && idx < resultDigits.count {
            let total = resultDigits[idx] + carry
            let (q, r) = total.quotientAndRemainder(dividingBy: base)
            resultDigits[idx] = r
            carry = q
            idx += 1
        }

        while resultDigits.count > 1 && resultDigits.last == 0 {
            resultDigits.removeLast()
        }

        var result = digitsToMagnitude(resultDigits)
        if (a < 0) != (b < 0) {
            result = -result
        }

        return result
    }

    nonisolated static func square(_ a: BigInt) -> BigInt {
        if a == 0 { return BigInt(0) }

        let aMag = a.magnitude

        if aMag.bitWidth < 4000 {
            return a * a
        }

        let aDigits = magnitudeToDigits(aMag)

        let n = nextPowerOf2(2 * aDigits.count)

        if n > maxTransformSize {
            return a * a
        }

        guard let r0 = nttSquare(aDigits, fftSize: n, primeIdx: 0),
              let r1 = nttSquare(aDigits, fftSize: n, primeIdx: 1),
              let r2 = nttSquare(aDigits, fftSize: n, primeIdx: 2) else {
            return a * a
        }

        var resultDigits = [BigInt](repeating: BigInt(0), count: n + 64)
        var carry = BigInt(0)

        let base = BigInt(digitBase)

        for i in 0..<n {
            let reconstructed = crtReconstruct(r0[i], r1[i], r2[i])
            let total = reconstructed + carry

            let (q, r) = total.quotientAndRemainder(dividingBy: base)
            resultDigits[i] = r
            carry = q
        }

        var idx = n
        while carry > 0 && idx < resultDigits.count {
            let total = resultDigits[idx] + carry
            let (q, r) = total.quotientAndRemainder(dividingBy: base)
            resultDigits[idx] = r
            carry = q
            idx += 1
        }

        while resultDigits.count > 1 && resultDigits.last == 0 {
            resultDigits.removeLast()
        }

        return digitsToMagnitude(resultDigits)
    }

    nonisolated private static func nextPowerOf2(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }
}
