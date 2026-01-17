import Foundation
import BigInt
import Accelerate

enum FFT {
    static let fftBaseBits = 15
    static let fftBase: Int64 = 32768
    static let fftBaseMask: UInt64 = 32767

    static func toDigits(_ m: BigUInt) -> [Double] {
        if m == 0 { return [0] }
        let w = m.words, totalBits = m.bitWidth
        var d = [Double]()
        var bp = 0, wi = 0
        var cw: UInt64 = w.count > 0 ? UInt64(w[0]) : 0
        var br = 64
        while bp < totalBits {
            var digit: UInt64 = 0, need = fftBaseBits, got = 0
            while need > 0 && wi < w.count {
                if br == 0 { wi += 1; if wi < w.count { cw = UInt64(w[wi]); br = 64 } else { break } }
                let take = min(need, br)
                digit |= (cw & ((1 << take) - 1)) << got
                cw >>= take; br -= take; need -= take; got += take
            }
            d.append(Double(digit & fftBaseMask))
            bp += fftBaseBits
        }
        return d
    }

    static func fromDigits(_ d: [Int64]) -> BigInt {
        if d.isEmpty { return BigInt(0) }
        var w: [UInt] = []
        var acc: UInt = 0, bits = 0
        for digit in d {
            let v = UInt(bitPattern: Int(digit))
            acc |= v << bits
            bits += fftBaseBits
            while bits >= 64 { w.append(acc); acc = v >> (fftBaseBits - (bits - 64)); bits -= 64 }
        }
        if bits > 0 || w.isEmpty { w.append(acc) }
        while w.count > 1 && w.last == 0 { w.removeLast() }
        return BigInt(sign: .plus, magnitude: BigUInt(words: w))
    }

    static func nextPow2(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }

    static func multiply(_ a: BigInt, _ b: BigInt) -> BigInt {
        if a == 0 || b == 0 { return BigInt(0) }

        let aMag = a.magnitude, bMag = b.magnitude
        if aMag.bitWidth + bMag.bitWidth < 3000 { return a * b }

        let sign: BigInt.Sign = (a < 0) != (b < 0) ? .minus : .plus
        let aDigits = toDigits(aMag)
        let bDigits = toDigits(bMag)
        let resultLen = aDigits.count + bDigits.count
        let fftSize = nextPow2(resultLen)
        let log2n = vDSP_Length(log2(Double(fftSize)))

        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else { return a * b }
        defer { vDSP_destroy_fftsetupD(setup) }

        var aReal = [Double](repeating: 0, count: fftSize)
        var aImag = [Double](repeating: 0, count: fftSize)
        var bReal = [Double](repeating: 0, count: fftSize)
        var bImag = [Double](repeating: 0, count: fftSize)
        var cReal = [Double](repeating: 0, count: fftSize)
        var cImag = [Double](repeating: 0, count: fftSize)

        for i in 0..<aDigits.count { aReal[i] = aDigits[i] }
        for i in 0..<bDigits.count { bReal[i] = bDigits[i] }

        var aSplit = DSPDoubleSplitComplex(realp: &aReal, imagp: &aImag)
        var bSplit = DSPDoubleSplitComplex(realp: &bReal, imagp: &bImag)
        var cSplit = DSPDoubleSplitComplex(realp: &cReal, imagp: &cImag)

        vDSP_fft_zipD(setup, &aSplit, 1, log2n, FFTDirection(kFFTDirection_Forward))
        vDSP_fft_zipD(setup, &bSplit, 1, log2n, FFTDirection(kFFTDirection_Forward))
        vDSP_zvmulD(&aSplit, 1, &bSplit, 1, &cSplit, 1, vDSP_Length(fftSize), 1)
        vDSP_fft_zipD(setup, &cSplit, 1, log2n, FFTDirection(kFFTDirection_Inverse))

        var scale = 1.0 / Double(fftSize)
        vDSP_vsmulD(cReal, 1, &scale, &cReal, 1, vDSP_Length(fftSize))

        let baseDouble = Double(fftBase)
        var result = [Int64](repeating: 0, count: fftSize + 64)
        var carry: Double = 0.0
        for i in 0..<fftSize {
            let totalValue = cReal[i] + carry
            let roundedValue = round(totalValue)
            let quotient = floor(roundedValue / baseDouble)
            result[i] = Int64(max(0, min(baseDouble - 1, roundedValue - quotient * baseDouble)))
            carry = quotient
        }
        var idx = fftSize
        while carry >= 0.5 && idx < result.count {
            let value = Double(result[idx]) + carry
            result[idx] = Int64(value.truncatingRemainder(dividingBy: baseDouble))
            carry = floor(value / baseDouble)
            idx += 1
        }
        while result.count > 1 && result.last == 0 { result.removeLast() }

        let magnitude = fromDigits(result).magnitude
        return BigInt(sign: sign, magnitude: magnitude)
    }
}

struct Zrt5 {
    var a: BigInt
    var b: BigInt

    func multiply(_ x: Zrt5) -> Zrt5 {
        let ac = FFT.multiply(a, x.a)
        let bd = FFT.multiply(b, x.b)
        let ad = FFT.multiply(a, x.b)
        let bc = FFT.multiply(b, x.a)
        let fiveBd = (bd << 2) + bd
        return Zrt5(a: ac + fiveBd, b: ad + bc)
    }

    func square() -> Zrt5 {
        let aa = FFT.multiply(a, a)
        let bb = FFT.multiply(b, b)
        let ab = FFT.multiply(a, b)
        let fiveBb = (bb << 2) + bb
        return Zrt5(a: aa + fiveBb, b: ab << 1)
    }

    mutating func rightShift(_ n: Int) {
        a >>= n
        b >>= n
    }
}

func fib(_ n: Int) -> BigInt {
    if n == 0 { return BigInt(0) }
    if n <= 2 { return BigInt(1) }

    var step = Zrt5(a: 1, b: 1)
    var result = Zrt5(a: 1, b: 1)
    var exp = n - 1

    while exp > 0 {
        if (exp & 1) != 0 {
            result = result.multiply(step)
            result.rightShift(1)
        }
        step = step.square()
        step.rightShift(1)
        exp >>= 1
    }

    return result.b
}

print("=== Fibonacci Benchmark ===\n")

for n in [1_000, 10_000, 100_000, 1_000_000, 3_000_000, 5_000_000, 10_000_000] {
    let start = Date()
    let f = fib(n)
    let elapsed = Date().timeIntervalSince(start) * 1000
    let bits = f.magnitude.bitWidth
    let expectedBits = Int(Double(n) * 0.6942)
    let decimalDigits = Int(Double(bits) * 0.30103)

    print("F(\(String(format: "%8d", n))): \(String(format: "%7.1f", elapsed))ms  \(bits) bits (~\(decimalDigits) digits)")

    let bitRatio = Double(bits) / Double(expectedBits)
    if bitRatio < 0.95 || bitRatio > 1.05 {
        print("  ⚠️  Expected ~\(expectedBits) bits, ratio=\(String(format: "%.3f", bitRatio))")
    }
}
