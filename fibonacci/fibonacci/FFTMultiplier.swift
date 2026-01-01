//
//  FFTMultiplier.swift
//  fibonacci
//
//  Optimized FFT multiplication using Accelerate/vDSP
//  Direct BigInt magnitude conversion, vectorized operations
//

import Foundation
import Accelerate
import BigInt

/// FFT-based multiplication for BigInt operations
enum FFTMultiplier {
    
    nonisolated private static let maxFFTSize = 1 << 24
    
    /// Base for FFT digits: 2^15 = 32768
    nonisolated private static let fftBase: Int64 = 32768
    nonisolated private static let fftBaseBits: Int = 15
    
    // MARK: - Public Interface
    
    nonisolated static func multiply(_ a: BigInt, _ b: BigInt) -> BigInt {
        let aMag = a.magnitude
        let bMag = b.magnitude
        let combinedBits = aMag.bitWidth + bMag.bitWidth
        
        if a == 0 || b == 0 {
            return BigInt(0)
        }
        
        // Dynamic: use FFT if combined bit width > 192
        if combinedBits < 192 {
            return a * b
        }
        
        let aDigits = magnitudeToDigits(aMag)
        let bDigits = magnitudeToDigits(bMag)
        
        let n = nextPowerOf2(2 * max(aDigits.count, bDigits.count))
        
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
        let aMag = a.magnitude
        
        if a == 0 {
            return BigInt(0)
        }
        
        if aMag.bitWidth < 96 {
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
    
    // MARK: - Direct BigInt Magnitude Conversion (O(n) using word access)
    
    /// Convert BigInt magnitude to base-2^15 digits using BigUInt division
    /// O(n) - uses BigUInt modulo and division operations (safe, no shift truncation issues)
    nonisolated private static func magnitudeToDigits(_ mag: BigInt.Magnitude) -> [Double] {
        if mag == 0 {
            return [0]
        }
        
        var value = mag
        var digits: [Double] = []
        let estimatedCount = (value.bitWidth + fftBaseBits - 1) / fftBaseBits
        digits.reserveCapacity(estimatedCount)
        let base = BigUInt(fftBase)
        
        while value > 0 {
            let remainder = value % base
            digits.append(Double(remainder))
            value /= base
        }
        
        return digits.isEmpty ? [0] : digits
    }
    
    /// Convert base-2^15 digits back to BigInt using direct word construction
    /// O(n) - builds UInt words directly, then creates BigUInt via init(words:)
    nonisolated private static func digitsToMagnitude(_ digits: [Int64]) -> BigInt {
        if digits.isEmpty {
            return BigInt(0)
        }
        
        // Build UInt words from digits using bit manipulation
        var words: [UInt] = []
        words.reserveCapacity((digits.count * fftBaseBits + 63) / 64)
        
        var bitAccumulator: UInt = 0
        var bitsInAccumulator: Int = 0
        
        // Process digits from least significant to most
        for digit in digits {
            // Add digit to accumulator (digits are positive, safe to convert to UInt)
            bitAccumulator |= UInt(truncatingIfNeeded: digit) << bitsInAccumulator
            bitsInAccumulator += fftBaseBits
            
            // Extract complete 64-bit words (UInt is 64-bit on Apple Silicon)
            while bitsInAccumulator >= 64 {
                words.append(bitAccumulator)
                bitAccumulator >>= 64
                bitsInAccumulator -= 64
            }
        }
        
        // Handle remaining bits
        if bitsInAccumulator > 0 || words.isEmpty {
            words.append(bitAccumulator)
        }
        
        // Remove trailing zero words (optimization)
        while words.count > 1 && words.last == 0 {
            words.removeLast()
        }
        
        // Create BigUInt directly from words array (O(1) - direct construction)
        let bigUInt = BigUInt(words: words)
        return BigInt(sign: .plus, magnitude: bigUInt)
    }
    
    // MARK: - FFT Operations (Complex FFT - standard for convolution)
    
    nonisolated private static func fftConvolve(_ a: [Double], _ b: [Double], fftSize n: Int) -> [Int64]? {
        let log2n = vDSP_Length(log2(Double(n)))
        guard (1 << log2n) == n, n >= 4 else {
            return nil
        }
        
        guard let fftSetup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetupD(fftSetup) }
        
        let aReal = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let aImag = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let bReal = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let bImag = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let cReal = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let cImag = UnsafeMutablePointer<Double>.allocate(capacity: n)
        
        defer {
            aReal.deallocate(); aImag.deallocate()
            bReal.deallocate(); bImag.deallocate()
            cReal.deallocate(); cImag.deallocate()
        }
        
        aReal.initialize(repeating: 0, count: n)
        aImag.initialize(repeating: 0, count: n)
        bReal.initialize(repeating: 0, count: n)
        bImag.initialize(repeating: 0, count: n)
        
        for i in 0..<a.count { aReal[i] = a[i] }
        for i in 0..<b.count { bReal[i] = b[i] }
        
        var aSplit = DSPDoubleSplitComplex(realp: aReal, imagp: aImag)
        var bSplit = DSPDoubleSplitComplex(realp: bReal, imagp: bImag)
        var cSplit = DSPDoubleSplitComplex(realp: cReal, imagp: cImag)
        
        vDSP_fft_zipD(fftSetup, &aSplit, 1, log2n, FFTDirection(kFFTDirection_Forward))
        vDSP_fft_zipD(fftSetup, &bSplit, 1, log2n, FFTDirection(kFFTDirection_Forward))
        vDSP_zvmulD(&aSplit, 1, &bSplit, 1, &cSplit, 1, vDSP_Length(n), 1)
        vDSP_fft_zipD(fftSetup, &cSplit, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        
        return extractResult(cReal, count: n)
    }
    
    nonisolated private static func fftSquare(_ a: [Double], fftSize n: Int) -> [Int64]? {
        let log2n = vDSP_Length(log2(Double(n)))
        guard (1 << log2n) == n, n >= 4 else {
            return nil
        }
        
        guard let fftSetup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetupD(fftSetup) }
        
        let aReal = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let aImag = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let cReal = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let cImag = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let temp = UnsafeMutablePointer<Double>.allocate(capacity: n)
        
        defer {
            aReal.deallocate(); aImag.deallocate()
            cReal.deallocate(); cImag.deallocate()
            temp.deallocate()
        }
        
        aReal.initialize(repeating: 0, count: n)
        aImag.initialize(repeating: 0, count: n)
        
        for i in 0..<a.count { aReal[i] = a[i] }
        
        var aSplit = DSPDoubleSplitComplex(realp: aReal, imagp: aImag)
        var cSplit = DSPDoubleSplitComplex(realp: cReal, imagp: cImag)
        
        vDSP_fft_zipD(fftSetup, &aSplit, 1, log2n, FFTDirection(kFFTDirection_Forward))
        
        // Vectorized complex square: (ar + ai*i)² = (ar² - ai²) + 2*ar*ai*i
        vDSP_vmulD(aReal, 1, aReal, 1, cReal, 1, vDSP_Length(n))      // ar²
        vDSP_vmulD(aImag, 1, aImag, 1, temp, 1, vDSP_Length(n))       // ai²
        vDSP_vsubD(temp, 1, cReal, 1, cReal, 1, vDSP_Length(n))       // ar² - ai²
        
        vDSP_vmulD(aReal, 1, aImag, 1, cImag, 1, vDSP_Length(n))      // ar*ai
        var two: Double = 2.0
        vDSP_vsmulD(cImag, 1, &two, cImag, 1, vDSP_Length(n))         // 2*ar*ai
        
        vDSP_fft_zipD(fftSetup, &cSplit, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        
        return extractResult(cReal, count: n)
    }
    
    nonisolated private static func extractResult(_ cReal: UnsafeMutablePointer<Double>, count n: Int) -> [Int64] {
        // Note: vDSP_fft_zipD with kFFTDirection_Inverse already scales by 1/n
        // So we don't need to scale again - using cReal[i] directly
        let baseDouble = Double(fftBase)
        var result = [Int64](repeating: 0, count: n + 32)  // Extra space for carries
        var carry: Double = 0.0  // Use Double for carry to handle large intermediate values
        for i in 0..<n {
            // Add carry (no extra scaling - inverse FFT already did 1/n)
            let totalValue = cReal[i] + carry
            let roundedValue = round(totalValue)
            
            // Use proper modulo arithmetic (much faster than while loop)
            // For positive values: digit = roundedValue - floor(roundedValue / baseDouble) * baseDouble
            let quotient = roundedValue / baseDouble
            let digitDouble = roundedValue - floor(quotient) * baseDouble
            
            // Ensure digit is in [0, baseDouble) range (handle any floating point errors)
            let clampedDigit = max(0.0, min(baseDouble - 1.0, digitDouble))
            
            // Extract digit (should be in [0, baseDouble))
            result[i] = Int64(clampedDigit)
            
            // Calculate carry: integer part of (roundedValue / baseDouble)
            carry = floor(quotient)
        }
        
        // Propagate remaining carry (process in chunks if very large)
        var idx = n
        while carry >= 0.5 && idx < result.count {
            let carryInt = min(Int64(carry), Int64.max)
            let value = result[idx] + carryInt
            result[idx] = value % fftBase
            carry = Double(value / fftBase)
            idx += 1
        }
        
        // Remove trailing zeros
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
