//
//  Zrt5.swift
//  fibonacci
//
//  ℤ[√5] ring for fast Fibonacci via binary exponentiation
//  Pure C++ spirit with deterministic predictive stopping
//

import Foundation
import BigInt

/// Element of ℤ[√5]: a + b√5
struct Zrt5 {
    var a: BigInt
    var b: BigInt
    
    nonisolated init(_ a: BigInt, _ b: BigInt) {
        self.a = a
        self.b = b
    }
    
    nonisolated init(_ a: Int, _ b: Int) {
        self.a = BigInt(a)
        self.b = BigInt(b)
    }
    
    /// Multiply in ℤ[√5]: (a + b√5)(c + d√5) = (ac + 5bd) + (ad + bc)√5
    nonisolated func multiply(_ x: Zrt5) -> Zrt5 {
        let ac = FFTMultiplier.multiply(a, x.a)
        let bd = FFTMultiplier.multiply(b, x.b)
        let ad = FFTMultiplier.multiply(a, x.b)
        let bc = FFTMultiplier.multiply(b, x.a)
        let fiveBd = (bd << 2) + bd
        return Zrt5(ac + fiveBd, ad + bc)
    }
    
    /// Square in ℤ[√5]: (a + b√5)² = (a² + 5b²) + 2ab√5
    nonisolated func square() -> Zrt5 {
        let aa = FFTMultiplier.square(a)
        let bb = FFTMultiplier.square(b)
        let ab = FFTMultiplier.multiply(a, b)
        let fiveBb = (bb << 2) + bb
        return Zrt5(aa + fiveBb, ab << 1)
    }
    
    nonisolated mutating func rightShift(_ n: Int) {
        a >>= n
        b >>= n
    }
}

/// Result of interruptible Fibonacci computation
struct FibResult {
    let n: UInt64
    let fib: BigInt
    let elapsedMs: Double
    let bitsProcessed: Int
    let bitsWithMul: Int
}

/// Compute F(n) using ℤ[√5] with deterministic predictive stopping
func fibonacciInterruptible(
    targetN: UInt64,
    clock: ContinuousClock,
    startTime: ContinuousClock.Instant,
    limitMs: Double,
    onProgress: ((UInt64, Double, Int, BigInt) -> Void)? = nil
) -> FibResult {
    
    print("[Zrt5] fibonacciInterruptible() called")
    print("[Zrt5]   - targetN: \(targetN)")
    print("[Zrt5]   - limitMs: \(limitMs)")
    
    if targetN == 0 {
        print("[Zrt5] targetN == 0, returning early")
        return FibResult(n: 0, fib: BigInt(0), elapsedMs: 0, bitsProcessed: 0, bitsWithMul: 0)
    }
    
    // Exact C++: init step/fib = (1,1), exp = n-1
    var step = Zrt5(1, 1)
    var fib = Zrt5(1, 1)
    var exp = targetN - 1
    
    print("[Zrt5] Initialization:")
    print("[Zrt5]   - step: Zrt5(1, 1)")
    print("[Zrt5]   - fib: Zrt5(1, 1)")
    print("[Zrt5]   - exp: \(exp) (targetN - 1)")
    
    // Bit tracking: start at 0, add 1 post-init (for F(1))
    var currentN: UInt64 = 0
    var bitPos: Int = 0
    var bitsWithMul: Int = 0
    
    // Add 1 post-init (we start with F(1))
    currentN = 1
    
    print("[Zrt5]   - currentN: \(currentN) (F(1))")
    print("[Zrt5]   - bitPos: \(bitPos)")
    
    // Per-operation timing - deterministic predictions
    var lastMulMs: Double = 0.05
    var lastSquareMs: Double = 0.05
    let growthFactor: Double = 3.0  // Deterministic growth estimate
    
    print("[Zrt5] Timing predictions:")
    print("[Zrt5]   - lastMulMs: \(lastMulMs)ms (initial)")
    print("[Zrt5]   - lastSquareMs: \(lastSquareMs)ms (initial)")
    print("[Zrt5]   - growthFactor: \(growthFactor)")
    print("[Zrt5] Starting main loop (exp > 0)...")
    
    var loopIteration = 0
    while exp > 0 {
        loopIteration += 1
        let loopStart = clock.now
        let elapsed = durationToMs(startTime.duration(to: loopStart))
        
        if bitPos <= 10 || loopIteration % 10 == 1 {
            print("[Zrt5] --- Loop iteration \(loopIteration) (bitPos: \(bitPos)) ---")
            print("[Zrt5]   - exp: \(exp) (0x\(String(exp, radix: 16)))")
            print("[Zrt5]   - elapsed: \(String(format: "%.3f", elapsed))ms")
        }
        
        let bitSet = (exp & 1) != 0
        if bitPos <= 10 || loopIteration % 10 == 1 {
            print("[Zrt5]   - bitSet (exp & 1): \(bitSet)")
        }
        
        if bitSet {
            // Predict multiply time (deterministic)
            let estMulMs = lastMulMs * growthFactor
            if bitPos <= 10 || loopIteration % 10 == 1 {
                print("[Zrt5]   - estMulMs: \(String(format: "%.3f", estMulMs))ms (lastMulMs * \(growthFactor))")
                print("[Zrt5]   - elapsed + estMulMs: \(String(format: "%.3f", elapsed + estMulMs))ms vs limitMs: \(limitMs)ms")
            }
            
            if elapsed + estMulMs <= limitMs {
                // Safe to multiply
                if bitPos <= 10 || loopIteration % 10 == 1 {
                    print("[Zrt5]   -> PERFORMING MULTIPLY (safe)")
                }
                let mulStart = clock.now
                fib = fib.multiply(step)
                fib.rightShift(1)
                let actualMulMs = durationToMs(mulStart.duration(to: clock.now))
                lastMulMs = max(actualMulMs, 0.001)
                
                // Add this bit to currentN only if multiply was performed
                currentN += (1 << bitPos)
                bitsWithMul += 1
                
                if bitPos <= 10 || loopIteration % 10 == 1 {
                    print("[Zrt5]   - actualMulMs: \(String(format: "%.3f", actualMulMs))ms")
                    print("[Zrt5]   - currentN: \(currentN) (added \(1 << bitPos))")
                    print("[Zrt5]   - bitsWithMul: \(bitsWithMul)")
                }
            } else {
                if bitPos <= 10 || loopIteration % 10 == 1 {
                    print("[Zrt5]   -> SKIPPING MULTIPLY (would exceed limit)")
                }
            }
            // else: skip multiply (treat bit as unset), fib remains valid
        }
        
        // Predict square time (deterministic)
        let elapsedNow = durationToMs(startTime.duration(to: clock.now))
        let estSquareMs = lastSquareMs * growthFactor
        if bitPos <= 10 || loopIteration % 10 == 1 {
            print("[Zrt5]   - estSquareMs: \(String(format: "%.3f", estSquareMs))ms (lastSquareMs * \(growthFactor))")
            print("[Zrt5]   - elapsedNow + estSquareMs: \(String(format: "%.3f", elapsedNow + estSquareMs))ms vs limitMs: \(limitMs)ms")
        }
        
        if elapsedNow + estSquareMs > limitMs {
            // Square would exceed limit - stop
            print("[Zrt5] -> STOPPING (square would exceed limit)")
            print("[Zrt5] Final result: n=\(currentN), bitsProcessed=\(bitPos), bitsWithMul=\(bitsWithMul), elapsed=\(String(format: "%.3f", elapsedNow))ms")
            return FibResult(
                n: currentN,
                fib: fib.b,
                elapsedMs: elapsedNow,
                bitsProcessed: bitPos,
                bitsWithMul: bitsWithMul
            )
        }
        
        // Perform square
        if bitPos <= 10 || loopIteration % 10 == 1 {
            print("[Zrt5]   -> PERFORMING SQUARE")
        }
        let squareStart = clock.now
        step = step.square()
        step.rightShift(1)
        let actualSquareMs = durationToMs(squareStart.duration(to: clock.now))
        lastSquareMs = max(actualSquareMs, 0.001)
        
        if bitPos <= 10 || loopIteration % 10 == 1 {
            print("[Zrt5]   - actualSquareMs: \(String(format: "%.3f", actualSquareMs))ms")
        }
        
        exp >>= 1
        bitPos += 1
        
        if bitPos <= 10 || loopIteration % 10 == 1 {
            print("[Zrt5]   - exp >>= 1, new exp: \(exp)")
            print("[Zrt5]   - bitPos incremented to: \(bitPos)")
        }
        
        // Progress callback every bit with current Fibonacci value
        let elapsedForProgress = durationToMs(startTime.duration(to: clock.now))
        onProgress?(currentN, elapsedForProgress, bitPos, fib.b)
    }
    
    // Completed full computation
    let elapsed = durationToMs(startTime.duration(to: clock.now))
    print("[Zrt5] Completed full computation (exp reached 0)")
    print("[Zrt5] Final result: n=\(currentN), bitsProcessed=\(bitPos), bitsWithMul=\(bitsWithMul), elapsed=\(String(format: "%.3f", elapsed))ms")
    return FibResult(
        n: currentN,
        fib: fib.b,
        elapsedMs: elapsed,
        bitsProcessed: bitPos,
        bitsWithMul: bitsWithMul
    )
}

private func durationToMs(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1_000_000_000_000_000.0
}
