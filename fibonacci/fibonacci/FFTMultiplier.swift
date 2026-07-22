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

enum TransformBackendPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case vDSP
    case mpsGraph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .vDSP: return "vDSP"
        case .mpsGraph: return "MPSGraph"
        }
    }

    var shortTitle: String {
        switch self {
        case .automatic: return "Auto"
        case .vDSP: return "vDSP"
        case .mpsGraph: return "MPS"
        }
    }
}

enum TransformBackend: String, Sendable {
    case bigInt
    case vDSP
    case mpsGraph

    var title: String {
        switch self {
        case .bigInt: return "BigInt"
        case .vDSP: return "Accelerate · vDSP"
        case .mpsGraph: return "Metal · MPSGraph"
        }
    }
}

struct TransformTelemetry: Sendable, Equatable {
    var requestedBackend: TransformBackendPreference
    var activeBackend: TransformBackend
    var fftSize: Int
    var workloadBits: Int
    var fallbackCount: Int
    var gpuAvailable: Bool
    var deviceName: String?
}

enum FFTMultiplier {
    nonisolated private final class SendableFFTSetup: @unchecked Sendable {
        let setup: FFTSetupD

        nonisolated init(setup: FFTSetupD) {
            self.setup = setup
        }
    }

    nonisolated private struct RuntimeState: Sendable {
        var preference: TransformBackendPreference
        var telemetry: TransformTelemetry
    }

    nonisolated(unsafe) private static var fftSetupCache: [vDSP_Length: SendableFFTSetup] = [:]
    nonisolated private static let fftSetupLock = OSAllocatedUnfairLock(initialState: ())
    nonisolated private static let automaticMPSWorkloadBitThreshold: Int? = nil
    nonisolated private static let maxVDSPFFTSize = 1 << 24
    nonisolated private static let maxMPSFFTSize = 1 << 22
    nonisolated private static let vDSPDigitBits = 15
    nonisolated private static let mpsMaximumDigitBits = 3
    nonisolated private static let integrityModulus: UInt64 = 4_294_967_291
    nonisolated private static let runtimeLock = OSAllocatedUnfairLock(
        initialState: RuntimeState(
            preference: .automatic,
            telemetry: TransformTelemetry(
                requestedBackend: .automatic,
                activeBackend: .bigInt,
                fftSize: 0,
                workloadBits: 0,
                fallbackCount: 0,
                gpuAvailable: MPSGraphFFTBackend.isAvailable,
                deviceName: MPSGraphFFTBackend.deviceName
            )
        )
    )

    // MARK: - Backend Configuration

    nonisolated static func setBackendPreference(_ preference: TransformBackendPreference) {
        runtimeLock.withLock { state in
            state.preference = preference
            state.telemetry.requestedBackend = preference
        }
    }

    nonisolated static func telemetrySnapshot() -> TransformTelemetry {
        runtimeLock.withLock { $0.telemetry }
    }

    nonisolated static var automaticBackendSummary: String {
        guard let threshold = automaticMPSWorkloadBitThreshold else {
            return "Automatic currently selects vDSP for transform work"
        }
        return "MPSGraph above \(threshold.formatted()) workload bits"
    }

    nonisolated private static func selectedBackend(workloadBits: Int) -> TransformBackend {
        let preference = runtimeLock.withLock { $0.preference }
        switch preference {
        case .automatic:
            guard let threshold = automaticMPSWorkloadBitThreshold else {
                return .vDSP
            }
            return MPSGraphFFTBackend.isAvailable && workloadBits >= threshold ? .mpsGraph : .vDSP
        case .vDSP:
            return .vDSP
        case .mpsGraph:
            return MPSGraphFFTBackend.isAvailable ? .mpsGraph : .vDSP
        }
    }

    nonisolated private static func recordBackend(
        _ backend: TransformBackend,
        fftSize: Int,
        workloadBits: Int
    ) {
        runtimeLock.withLock { state in
            state.telemetry.requestedBackend = state.preference
            state.telemetry.activeBackend = backend
            state.telemetry.fftSize = fftSize
            state.telemetry.workloadBits = workloadBits
            state.telemetry.gpuAvailable = MPSGraphFFTBackend.isAvailable
            state.telemetry.deviceName = MPSGraphFFTBackend.deviceName
        }
    }

    nonisolated private static func recordFallback(workloadBits: Int) {
        runtimeLock.withLock { state in
            state.telemetry.fallbackCount += 1
            state.telemetry.workloadBits = workloadBits
        }
    }

    // MARK: - Public Interface

    nonisolated static func multiply(_ a: BigInt, _ b: BigInt) -> BigInt {
        if a == 0 || b == 0 { return BigInt(0) }

        let aMagnitude = a.magnitude
        let bMagnitude = b.magnitude
        let workloadBits = aMagnitude.bitWidth + bMagnitude.bitWidth

        if workloadBits < 3000 {
            recordBackend(.bigInt, fftSize: 0, workloadBits: workloadBits)
            return a * b
        }

        if selectedBackend(workloadBits: workloadBits) == .mpsGraph {
            if let result = mpsMultiply(
                a,
                b,
                aMagnitude: aMagnitude,
                bMagnitude: bMagnitude,
                workloadBits: workloadBits
            ) {
                return result
            }
            recordFallback(workloadBits: workloadBits)
        }

        if let result = vDSPMultiply(
            a,
            b,
            aMagnitude: aMagnitude,
            bMagnitude: bMagnitude,
            workloadBits: workloadBits
        ) {
            return result
        }

        recordFallback(workloadBits: workloadBits)
        recordBackend(.bigInt, fftSize: 0, workloadBits: workloadBits)
        return a * b
    }

    nonisolated static func square(_ a: BigInt) -> BigInt {
        if a == 0 { return BigInt(0) }

        let magnitude = a.magnitude
        let workloadBits = 2 * magnitude.bitWidth

        if magnitude.bitWidth < 1500 {
            recordBackend(.bigInt, fftSize: 0, workloadBits: workloadBits)
            return a * a
        }

        if selectedBackend(workloadBits: workloadBits) == .mpsGraph {
            if let result = mpsSquare(
                magnitude,
                workloadBits: workloadBits
            ) {
                return result
            }
            recordFallback(workloadBits: workloadBits)
        }

        if let result = vDSPSquare(magnitude, workloadBits: workloadBits) {
            return result
        }

        recordFallback(workloadBits: workloadBits)
        recordBackend(.bigInt, fftSize: 0, workloadBits: workloadBits)
        return a * a
    }

    // MARK: - MPSGraph Float32 Convolution

    nonisolated private static func mpsMultiply(
        _ a: BigInt,
        _ b: BigInt,
        aMagnitude: BigUInt,
        bMagnitude: BigUInt,
        workloadBits: Int
    ) -> BigInt? {
        let digitBits = mpsDigitBits(
            firstBitWidth: aMagnitude.bitWidth,
            secondBitWidth: bMagnitude.bitWidth
        )
        let aDigits: [Float] = magnitudeToDigits(aMagnitude, digitBits: digitBits)
        let bDigits: [Float] = magnitudeToDigits(bMagnitude, digitBits: digitBits)
        let fftSize = nextPowerOf2(aDigits.count + bDigits.count)

        guard fftSize <= maxMPSFFTSize,
              let coefficients = MPSGraphFFTBackend.multiply(aDigits, bDigits, fftSize: fftSize),
              let resultDigits = extractResult(
                coefficients,
                count: fftSize,
                digitBits: digitBits
              ),
              residue(resultDigits, digitBits: digitBits)
                == residue(aDigits, digitBits: digitBits)
                    * residue(bDigits, digitBits: digitBits)
                    % integrityModulus else {
            return nil
        }

        var result = digitsToMagnitude(resultDigits, digitBits: digitBits)
        if (a < 0) != (b < 0) {
            result = -result
        }
        recordBackend(.mpsGraph, fftSize: fftSize, workloadBits: workloadBits)
        return result
    }

    nonisolated private static func mpsSquare(
        _ magnitude: BigUInt,
        workloadBits: Int
    ) -> BigInt? {
        let digitBits = mpsDigitBits(
            firstBitWidth: magnitude.bitWidth,
            secondBitWidth: magnitude.bitWidth
        )
        let digits: [Float] = magnitudeToDigits(magnitude, digitBits: digitBits)
        let fftSize = nextPowerOf2(2 * digits.count)

        guard fftSize <= maxMPSFFTSize,
              let coefficients = MPSGraphFFTBackend.square(digits, fftSize: fftSize),
              let resultDigits = extractResult(
                coefficients,
                count: fftSize,
                digitBits: digitBits
              ) else {
            return nil
        }

        let inputResidue = residue(digits, digitBits: digitBits)
        guard residue(resultDigits, digitBits: digitBits)
                == inputResidue * inputResidue % integrityModulus else {
            return nil
        }

        recordBackend(.mpsGraph, fftSize: fftSize, workloadBits: workloadBits)
        return digitsToMagnitude(resultDigits, digitBits: digitBits)
    }

    /// Float32 stores integers exactly through 2²⁴. Use the widest small radix
    /// whose largest direct convolution coefficient stays below half that range.
    nonisolated private static func mpsDigitBits(
        firstBitWidth: Int,
        secondBitWidth: Int
    ) -> Int {
        let exactCoefficientBudget = 1 << 21
        for digitBits in stride(from: mpsMaximumDigitBits, through: 1, by: -1) {
            let firstCount = (firstBitWidth + digitBits - 1) / digitBits
            let secondCount = (secondBitWidth + digitBits - 1) / digitBits
            let maximumDigit = (1 << digitBits) - 1
            if min(firstCount, secondCount) * maximumDigit * maximumDigit <= exactCoefficientBudget {
                return digitBits
            }
        }
        return 1
    }

    // MARK: - Accelerate Double Convolution

    nonisolated private static func vDSPMultiply(
        _ a: BigInt,
        _ b: BigInt,
        aMagnitude: BigUInt,
        bMagnitude: BigUInt,
        workloadBits: Int
    ) -> BigInt? {
        let aDigits: [Double] = magnitudeToDigits(aMagnitude, digitBits: vDSPDigitBits)
        let bDigits: [Double] = magnitudeToDigits(bMagnitude, digitBits: vDSPDigitBits)
        let fftSize = nextPowerOf2(aDigits.count + bDigits.count)

        guard fftSize <= maxVDSPFFTSize,
              let resultDigits = fftConvolve(aDigits, bDigits, fftSize: fftSize),
              residue(resultDigits, digitBits: vDSPDigitBits)
                == residue(aDigits, digitBits: vDSPDigitBits)
                    * residue(bDigits, digitBits: vDSPDigitBits)
                    % integrityModulus else {
            return nil
        }

        var result = digitsToMagnitude(resultDigits, digitBits: vDSPDigitBits)
        if (a < 0) != (b < 0) {
            result = -result
        }
        recordBackend(.vDSP, fftSize: fftSize, workloadBits: workloadBits)
        return result
    }

    nonisolated private static func vDSPSquare(
        _ magnitude: BigUInt,
        workloadBits: Int
    ) -> BigInt? {
        let digits: [Double] = magnitudeToDigits(magnitude, digitBits: vDSPDigitBits)
        let fftSize = nextPowerOf2(2 * digits.count)

        guard fftSize <= maxVDSPFFTSize,
              let resultDigits = fftSquare(digits, fftSize: fftSize) else {
            return nil
        }

        let inputResidue = residue(digits, digitBits: vDSPDigitBits)
        guard residue(resultDigits, digitBits: vDSPDigitBits)
                == inputResidue * inputResidue % integrityModulus else {
            return nil
        }

        recordBackend(.vDSP, fftSize: fftSize, workloadBits: workloadBits)
        return digitsToMagnitude(resultDigits, digitBits: vDSPDigitBits)
    }

    // MARK: - Digit Conversion

    nonisolated private static func magnitudeToDigits<T: BinaryFloatingPoint>(
        _ magnitude: BigUInt,
        digitBits: Int
    ) -> [T] {
        if magnitude == 0 { return [0] }

        let words = magnitude.words
        let totalBits = magnitude.bitWidth
        let digitCount = (totalBits + digitBits - 1) / digitBits
        let digitMask = UInt64((1 << digitBits) - 1)

        var digits: [T] = []
        digits.reserveCapacity(digitCount)

        var bitPosition = 0
        var wordIndex = 0
        var currentWord = UInt64(words[0])
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
                digit |= (currentWord & mask) << bitsCollected
                currentWord >>= bitsToTake
                bitsRemainingInWord -= bitsToTake
                bitsNeeded -= bitsToTake
                bitsCollected += bitsToTake
            }

            digits.append(T(digit & digitMask))
            bitPosition += digitBits
        }

        return digits
    }

    nonisolated private static func digitsToMagnitude(
        _ digits: [Int64],
        digitBits: Int
    ) -> BigInt {
        if digits.isEmpty { return BigInt(0) }

        var words: [UInt] = []
        words.reserveCapacity((digits.count * digitBits + 63) / 64)

        var accumulator: UInt = 0
        var bitsInAccumulator = 0

        for digit in digits {
            let value = UInt(digit)
            accumulator |= value << bitsInAccumulator
            bitsInAccumulator += digitBits

            while bitsInAccumulator >= 64 {
                words.append(accumulator)
                accumulator = value >> (digitBits - (bitsInAccumulator - 64))
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

    /// Independently checks the reconstructed convolution modulo a 32-bit prime.
    nonisolated private static func residue<T: BinaryFloatingPoint>(
        _ digits: [T],
        digitBits: Int
    ) -> UInt64 {
        var value: UInt64 = 0
        let base = UInt64(1 << digitBits)
        for digit in digits.reversed() {
            value = (value * base + UInt64(digit)) % integrityModulus
        }
        return value
    }

    nonisolated private static func residue(
        _ digits: [Int64],
        digitBits: Int
    ) -> UInt64 {
        var value: UInt64 = 0
        let base = UInt64(1 << digitBits)
        for digit in digits.reversed() {
            value = (value * base + UInt64(digit)) % integrityModulus
        }
        return value
    }

    // MARK: - vDSP FFT Operations

    nonisolated private static func getSetup(log2n: vDSP_Length) -> FFTSetupD? {
        let wrapper = fftSetupLock.withLock { () -> SendableFFTSetup? in
            if let setup = fftSetupCache[log2n] {
                return setup
            }
            guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
                return nil
            }
            let wrapper = SendableFFTSetup(setup: setup)
            fftSetupCache[log2n] = wrapper
            return wrapper
        }
        return wrapper?.setup
    }

    nonisolated private static func fftConvolve(
        _ a: [Double],
        _ b: [Double],
        fftSize n: Int
    ) -> [Int64]? {
        let log2n = vDSP_Length(log2(Double(n)))
        guard (1 << log2n) == n, n >= 4,
              let fftSetup = getSetup(log2n: log2n) else {
            return nil
        }

        var aReal = [Double](repeating: 0, count: n)
        var aImag = [Double](repeating: 0, count: n)
        var bReal = [Double](repeating: 0, count: n)
        var bImag = [Double](repeating: 0, count: n)
        var cReal = [Double](repeating: 0, count: n)
        var cImag = [Double](repeating: 0, count: n)
        aReal.replaceSubrange(0..<a.count, with: a)
        bReal.replaceSubrange(0..<b.count, with: b)

        aReal.withUnsafeMutableBufferPointer { aRealBuffer in
            aImag.withUnsafeMutableBufferPointer { aImagBuffer in
                bReal.withUnsafeMutableBufferPointer { bRealBuffer in
                    bImag.withUnsafeMutableBufferPointer { bImagBuffer in
                        cReal.withUnsafeMutableBufferPointer { cRealBuffer in
                            cImag.withUnsafeMutableBufferPointer { cImagBuffer in
                                var aSplit = DSPDoubleSplitComplex(
                                    realp: aRealBuffer.baseAddress!,
                                    imagp: aImagBuffer.baseAddress!
                                )
                                var bSplit = DSPDoubleSplitComplex(
                                    realp: bRealBuffer.baseAddress!,
                                    imagp: bImagBuffer.baseAddress!
                                )
                                var cSplit = DSPDoubleSplitComplex(
                                    realp: cRealBuffer.baseAddress!,
                                    imagp: cImagBuffer.baseAddress!
                                )

                                vDSP_fft_zipD(fftSetup, &aSplit, 1, log2n, FFTDirection(kFFTDirection_Forward))
                                vDSP_fft_zipD(fftSetup, &bSplit, 1, log2n, FFTDirection(kFFTDirection_Forward))
                                vDSP_zvmulD(&aSplit, 1, &bSplit, 1, &cSplit, 1, vDSP_Length(n), 1)
                                vDSP_fft_zipD(fftSetup, &cSplit, 1, log2n, FFTDirection(kFFTDirection_Inverse))

                                var scale = 1.0 / Double(n)
                                vDSP_vsmulD(
                                    cRealBuffer.baseAddress!,
                                    1,
                                    &scale,
                                    cRealBuffer.baseAddress!,
                                    1,
                                    vDSP_Length(n)
                                )
                            }
                        }
                    }
                }
            }
        }

        return extractResult(cReal, count: n, digitBits: vDSPDigitBits)
    }

    nonisolated private static func fftSquare(
        _ a: [Double],
        fftSize n: Int
    ) -> [Int64]? {
        let log2n = vDSP_Length(log2(Double(n)))
        guard (1 << log2n) == n, n >= 4,
              let fftSetup = getSetup(log2n: log2n) else {
            return nil
        }

        var aReal = [Double](repeating: 0, count: n)
        var aImag = [Double](repeating: 0, count: n)
        var cReal = [Double](repeating: 0, count: n)
        var cImag = [Double](repeating: 0, count: n)
        aReal.replaceSubrange(0..<a.count, with: a)

        aReal.withUnsafeMutableBufferPointer { aRealBuffer in
            aImag.withUnsafeMutableBufferPointer { aImagBuffer in
                cReal.withUnsafeMutableBufferPointer { cRealBuffer in
                    cImag.withUnsafeMutableBufferPointer { cImagBuffer in
                        var aSplit = DSPDoubleSplitComplex(
                            realp: aRealBuffer.baseAddress!,
                            imagp: aImagBuffer.baseAddress!
                        )
                        var cSplit = DSPDoubleSplitComplex(
                            realp: cRealBuffer.baseAddress!,
                            imagp: cImagBuffer.baseAddress!
                        )

                        vDSP_fft_zipD(fftSetup, &aSplit, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        vDSP_zvmulD(&aSplit, 1, &aSplit, 1, &cSplit, 1, vDSP_Length(n), 1)
                        vDSP_fft_zipD(fftSetup, &cSplit, 1, log2n, FFTDirection(kFFTDirection_Inverse))

                        var scale = 1.0 / Double(n)
                        vDSP_vsmulD(
                            cRealBuffer.baseAddress!,
                            1,
                            &scale,
                            cRealBuffer.baseAddress!,
                            1,
                            vDSP_Length(n)
                        )
                    }
                }
            }
        }

        return extractResult(cReal, count: n, digitBits: vDSPDigitBits)
    }

    nonisolated private static func extractResult<T: BinaryFloatingPoint>(
        _ coefficients: [T],
        count: Int,
        digitBits: Int
    ) -> [Int64]? {
        let base = Double(1 << digitBits)
        var result = [Int64](repeating: 0, count: count + 64)
        var carry = 0.0

        for index in 0..<count {
            let total = Double(coefficients[index]) + carry
            guard total.isFinite else { return nil }

            let rounded = total.rounded()
            let quotient = floor(rounded / base)
            let digit = rounded - quotient * base
            result[index] = Int64(max(0, min(base - 1, digit)))
            carry = quotient
        }

        var index = count
        while carry >= 0.5 && index < result.count {
            let value = Double(result[index]) + carry
            result[index] = Int64(value.truncatingRemainder(dividingBy: base))
            carry = floor(value / base)
            index += 1
        }

        while result.count > 1 && result.last == 0 {
            result.removeLast()
        }
        return result
    }

    nonisolated private static func nextPowerOf2(_ value: Int) -> Int {
        var result = 1
        while result < value {
            result <<= 1
        }
        return result
    }
}
