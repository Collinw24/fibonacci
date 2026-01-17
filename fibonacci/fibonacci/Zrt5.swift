//
//  Zrt5.swift
//  fibonacci
//
//  ℤ[√5] ring for fast Fibonacci via binary exponentiation
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
