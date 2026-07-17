//
//  FFTMultiplier.swift
//  fibonacci
//
//  High-performance FFT multiplication using Accelerate/vDSP
//  O(n log n) multiplication with O(n) digit conversion
//

import Foundation
import Accelerate
import BigInt

enum FFTMultiplier {
    nonisolated private final class SendableFFTSetup: @unchecked Sendable {
        let setup: FFTSetupD
        init(setup: FFTSetupD) {
            self.setup = setup
        }
    }

    nonisolated(unsafe) private static var fftSetupCache: [vDSP_Length: SendableFFTSetup] = [:]
    nonisolated private static let fftSetupLock = OSAllocatedUnfairLock(initialState: ())

    nonisolated private static func getSetup(log2n: vDSP_Length) -> FFTSetupD? {
        let wrap = fftSetupLock.withLock { () -> SendableFFTSetup? in
            if let setup = fftSetupCache[log2n] {
                return setup
            }
            guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
                return nil
            }
            let wrap = SendableFFTSetup(setup: setup)
            fftSetupCache[log2n] = wrap
            return wrap
        }
        return wrap?.setup
    }

    nonisolated private static let maxFFTSize = 1 << 24
    nonisolated private static let fftBase: Int64 = 32768
    nonisolated private static let fftBaseBits: Int = 15
    nonisolated private static let fftBaseMask: UInt64 = 32767
    // MARK: - Public Interface

    nonisolated static func multiply(_ a: BigInt, _ b: BigInt) -> BigInt {
        if a == 0 || b == 0 { return BigInt(0) }

        let aMag = a.magnitude
        let bMag = b.magnitude
        let combinedBits = aMag.bitWidth + bMag.bitWidth

        if combinedBits < 3000 {
            return a * b
        }

        let aDigits = magnitudeToDigits(aMag)
        let bDigits = magnitudeToDigits(bMag)

        let n = nextPowerOf2(aDigits.count + bDigits.count)

        if n > maxFFTSize {
            return a * b
        }

        guard let resultDigits = fftConvolve(aDigits, bDigits, fftSize: n) else {
            return a * b
        }

        var result = digitsToMagnitude(resultDigits)
        if (a < 0) != (b < 0) { result = -result }

        return result
    }

    nonisolated static func square(_ a: BigInt) -> BigInt {
        if a == 0 { return BigInt(0) }

        let aMag = a.magnitude

        if aMag.bitWidth < 1500 {
            return a * a
        }

        let aDigits = magnitudeToDigits(aMag)
        let n = nextPowerOf2(2 * aDigits.count)

        if n > maxFFTSize {
            return a * a
        }

        guard let resultDigits = fftSquare(aDigits, fftSize: n) else {
            return a * a
        }

        return digitsToMagnitude(resultDigits)
    }

    // MARK: - O(n) Digit Conversion via Bit Manipulation

    nonisolated private static func magnitudeToDigits(_ mag: BigUInt) -> [Double] {
        if mag == 0 { return [0] }

        let words = mag.words
        let totalBits = mag.bitWidth
        let digitCount = (totalBits + fftBaseBits - 1) / fftBaseBits

        var digits = [Double]()
        digits.reserveCapacity(digitCount)

        var bitPosition = 0
        var wordIndex = 0
        var currentWord: UInt64 = words.count > 0 ? UInt64(words[0]) : 0
        var bitsRemainingInWord = 64

        while bitPosition < totalBits {
            var digit: UInt64 = 0
            var bitsNeeded = fftBaseBits
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

            digits.append(Double(digit & fftBaseMask))
            bitPosition += fftBaseBits
        }

        return digits
    }

    nonisolated private static func digitsToMagnitude(_ digits: [Int64]) -> BigInt {
        if digits.isEmpty { return BigInt(0) }

        var words: [UInt] = []
        let estimatedWords = (digits.count * fftBaseBits + 63) / 64
        words.reserveCapacity(estimatedWords)

        var accumulator: UInt = 0
        var bitsInAccumulator = 0

        for digit in digits {
            let d = UInt(bitPattern: Int(digit))
            accumulator |= d << bitsInAccumulator
            bitsInAccumulator += fftBaseBits

            while bitsInAccumulator >= 64 {
                words.append(accumulator)
                accumulator = d >> (fftBaseBits - (bitsInAccumulator - 64))
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

    // MARK: - FFT Operations

    nonisolated private static func fftConvolve(_ a: [Double], _ b: [Double], fftSize n: Int) -> [Int64]? {
        let log2n = vDSP_Length(log2(Double(n)))
        guard (1 << log2n) == n, n >= 4 else { return nil }

        guard let fftSetup = getSetup(log2n: log2n) else { return nil }

        var aReal = [Double](repeating: 0, count: n)
        var aImag = [Double](repeating: 0, count: n)
        var bReal = [Double](repeating: 0, count: n)
        var bImag = [Double](repeating: 0, count: n)
        var cReal = [Double](repeating: 0, count: n)
        var cImag = [Double](repeating: 0, count: n)

        for i in 0..<a.count { aReal[i] = a[i] }
        for i in 0..<b.count { bReal[i] = b[i] }

        aReal.withUnsafeMutableBufferPointer { aRealBuf in
            aImag.withUnsafeMutableBufferPointer { aImagBuf in
                bReal.withUnsafeMutableBufferPointer { bRealBuf in
                    bImag.withUnsafeMutableBufferPointer { bImagBuf in
                        cReal.withUnsafeMutableBufferPointer { cRealBuf in
                            cImag.withUnsafeMutableBufferPointer { cImagBuf in
                                var aSplit = DSPDoubleSplitComplex(realp: aRealBuf.baseAddress!, imagp: aImagBuf.baseAddress!)
                                var bSplit = DSPDoubleSplitComplex(realp: bRealBuf.baseAddress!, imagp: bImagBuf.baseAddress!)
                                var cSplit = DSPDoubleSplitComplex(realp: cRealBuf.baseAddress!, imagp: cImagBuf.baseAddress!)

                                vDSP_fft_zipD(fftSetup, &aSplit, 1, log2n, FFTDirection(kFFTDirection_Forward))
                                vDSP_fft_zipD(fftSetup, &bSplit, 1, log2n, FFTDirection(kFFTDirection_Forward))
                                vDSP_zvmulD(&aSplit, 1, &bSplit, 1, &cSplit, 1, vDSP_Length(n), 1)
                                vDSP_fft_zipD(fftSetup, &cSplit, 1, log2n, FFTDirection(kFFTDirection_Inverse))

                                var scale = 1.0 / Double(n)
                                vDSP_vsmulD(cRealBuf.baseAddress!, 1, &scale, cRealBuf.baseAddress!, 1, vDSP_Length(n))
                            }
                        }
                    }
                }
            }
        }

        return extractResult(cReal, count: n)
    }

    nonisolated private static func fftSquare(_ a: [Double], fftSize n: Int) -> [Int64]? {
        let log2n = vDSP_Length(log2(Double(n)))
        guard (1 << log2n) == n, n >= 4 else { return nil }

        guard let fftSetup = getSetup(log2n: log2n) else { return nil }

        var aReal = [Double](repeating: 0, count: n)
        var aImag = [Double](repeating: 0, count: n)
        var cReal = [Double](repeating: 0, count: n)
        var cImag = [Double](repeating: 0, count: n)

        for i in 0..<a.count { aReal[i] = a[i] }

        aReal.withUnsafeMutableBufferPointer { aRealBuf in
            aImag.withUnsafeMutableBufferPointer { aImagBuf in
                cReal.withUnsafeMutableBufferPointer { cRealBuf in
                    cImag.withUnsafeMutableBufferPointer { cImagBuf in
                        var aSplit = DSPDoubleSplitComplex(realp: aRealBuf.baseAddress!, imagp: aImagBuf.baseAddress!)
                        var cSplit = DSPDoubleSplitComplex(realp: cRealBuf.baseAddress!, imagp: cImagBuf.baseAddress!)

                        vDSP_fft_zipD(fftSetup, &aSplit, 1, log2n, FFTDirection(kFFTDirection_Forward))

                        vDSP_zvmulD(&aSplit, 1, &aSplit, 1, &cSplit, 1, vDSP_Length(n), 1)

                        vDSP_fft_zipD(fftSetup, &cSplit, 1, log2n, FFTDirection(kFFTDirection_Inverse))

                        var scale = 1.0 / Double(n)
                        vDSP_vsmulD(cRealBuf.baseAddress!, 1, &scale, cRealBuf.baseAddress!, 1, vDSP_Length(n))
                    }
                }
            }
        }

        return extractResult(cReal, count: n)
    }

    nonisolated private static func extractResult(_ cReal: [Double], count n: Int) -> [Int64] {
        let baseDouble = Double(fftBase)
        var result = [Int64](repeating: 0, count: n + 64)
        var carry: Double = 0.0

        for i in 0..<n {
            let totalValue = cReal[i] + carry
            let roundedValue = round(totalValue)

            let quotient = floor(roundedValue / baseDouble)
            let digit = roundedValue - quotient * baseDouble

            result[i] = Int64(max(0, min(baseDouble - 1, digit)))
            carry = quotient
        }

        var idx = n
        while carry >= 0.5 && idx < result.count {
            let value = Double(result[idx]) + carry
            result[idx] = Int64(value.truncatingRemainder(dividingBy: baseDouble))
            carry = floor(value / baseDouble)
            idx += 1
        }

        while result.count > 1 && result.last == 0 {
            result.removeLast()
        }

        return result
    }

    nonisolated private static func nextPowerOf2(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }
}
