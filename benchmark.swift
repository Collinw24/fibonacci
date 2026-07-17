#!/usr/bin/env swift

// Standalone Fibonacci Benchmark
// Run with: swift benchmark.swift
// Or: chmod +x benchmark.swift && ./benchmark.swift

import Foundation
import Accelerate

// MARK: - Minimal BigInt (for standalone testing)

struct BigNum: CustomStringConvertible {
    var words: [UInt64]

    init(_ value: Int) {
        words = value == 0 ? [0] : [UInt64(value)]
    }

    init(words: [UInt64]) {
        self.words = words
        normalize()
    }

    mutating func normalize() {
        while words.count > 1 && words.last == 0 {
            words.removeLast()
        }
    }

    var bitWidth: Int {
        guard let last = words.last, last != 0 else { return 0 }
        return (words.count - 1) * 64 + (64 - last.leadingZeroBitCount)
    }

    var description: String {
        "\(bitWidth) bits"
    }

    var digitCount: Int {
        Int(Double(bitWidth) * 0.30103) + 1
    }

    static func + (lhs: BigNum, rhs: BigNum) -> BigNum {
        var result = [UInt64]()
        let maxLen = max(lhs.words.count, rhs.words.count)
        result.reserveCapacity(maxLen + 1)

        var carry: UInt64 = 0
        for i in 0..<maxLen {
            let a = i < lhs.words.count ? lhs.words[i] : 0
            let b = i < rhs.words.count ? rhs.words[i] : 0
            let (sum1, overflow1) = a.addingReportingOverflow(b)
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
            result.append(sum2)
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        if carry > 0 {
            result.append(carry)
        }
        return BigNum(words: result)
    }

    static func << (lhs: BigNum, rhs: Int) -> BigNum {
        if rhs == 0 { return lhs }
        let wordShift = rhs / 64
        let bitShift = rhs % 64

        var result = [UInt64](repeating: 0, count: lhs.words.count + wordShift + 1)

        if bitShift == 0 {
            for i in 0..<lhs.words.count {
                result[i + wordShift] = lhs.words[i]
            }
        } else {
            var carry: UInt64 = 0
            for i in 0..<lhs.words.count {
                result[i + wordShift] = (lhs.words[i] << bitShift) | carry
                carry = lhs.words[i] >> (64 - bitShift)
            }
            if carry > 0 {
                result[lhs.words.count + wordShift] = carry
            }
        }
        return BigNum(words: result)
    }

    static func >> (lhs: BigNum, rhs: Int) -> BigNum {
        if rhs == 0 { return lhs }
        let wordShift = rhs / 64
        let bitShift = rhs % 64

        if wordShift >= lhs.words.count { return BigNum(0) }

        var result = [UInt64]()
        result.reserveCapacity(lhs.words.count - wordShift)

        if bitShift == 0 {
            for i in wordShift..<lhs.words.count {
                result.append(lhs.words[i])
            }
        } else {
            for i in wordShift..<lhs.words.count {
                var word = lhs.words[i] >> bitShift
                if i + 1 < lhs.words.count {
                    word |= lhs.words[i + 1] << (64 - bitShift)
                }
                result.append(word)
            }
        }
        return BigNum(words: result)
    }

    // O(n²) schoolbook multiply - slow but correct for verification
    static func * (lhs: BigNum, rhs: BigNum) -> BigNum {
        let n = lhs.words.count
        let m = rhs.words.count
        var result = [UInt64](repeating: 0, count: n + m)

        for i in 0..<n {
            var carry: UInt64 = 0
            for j in 0..<m {
                let (hi, lo) = lhs.words[i].multipliedFullWidth(by: rhs.words[j])
                let (sum1, o1) = result[i + j].addingReportingOverflow(lo)
                let (sum2, o2) = sum1.addingReportingOverflow(carry)
                result[i + j] = sum2
                carry = hi + (o1 ? 1 : 0) + (o2 ? 1 : 0)
            }
            result[i + m] = carry
        }
        return BigNum(words: result)
    }
}

// MARK: - Z[√5] Ring

struct Zrt5 {
    var a: BigNum
    var b: BigNum

    init(_ a: Int, _ b: Int) {
        self.a = BigNum(a)
        self.b = BigNum(b)
    }

    init(_ a: BigNum, _ b: BigNum) {
        self.a = a
        self.b = b
    }

    func multiply(_ x: Zrt5) -> Zrt5 {
        let ac = a * x.a
        let bd = b * x.b
        let ad = a * x.b
        let bc = b * x.a
        let fiveBd = (bd << 2) + bd
        return Zrt5(ac + fiveBd, ad + bc)
    }

    func square() -> Zrt5 {
        let aa = a * a
        let bb = b * b
        let ab = a * b
        let fiveBb = (bb << 2) + bb
        return Zrt5(aa + fiveBb, ab << 1)
    }

    mutating func rightShift(_ n: Int) {
        a = a >> n
        b = b >> n
    }
}

// MARK: - Fibonacci

func fibonacci(_ n: UInt64) -> BigNum {
    if n == 0 { return BigNum(0) }
    if n <= 2 { return BigNum(1) }

    var step = Zrt5(1, 1)
    var fib = Zrt5(1, 1)
    var exp = n - 1

    while exp > 0 {
        if (exp & 1) != 0 {
            fib = fib.multiply(step)
            fib.rightShift(1)
        }
        step = step.square()
        step.rightShift(1)
        exp >>= 1
    }

    return fib.b
}

// MARK: - Benchmark

func benchmark(_ n: UInt64) -> (timeMs: Double, digits: Int) {
    let start = CFAbsoluteTimeGetCurrent()
    let result = fibonacci(n)
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    return (elapsed, result.digitCount)
}

print("=== Fibonacci Benchmark (Standalone - No FFT) ===")
print("This uses O(n²) schoolbook multiplication")
print("Compare with app which uses O(n log n) FFT\n")

let targets: [UInt64] = [100, 1000, 5000, 10000]

for n in targets {
    let (time, digits) = benchmark(n)
    print("F(\(n)): \(String(format: "%.2f", time))ms, ~\(digits) digits")
}

print("\n=== Done ===")
print("If these are fast, the issue is in FFT integration.")
print("If these are slow too, the issue is in the math.")
