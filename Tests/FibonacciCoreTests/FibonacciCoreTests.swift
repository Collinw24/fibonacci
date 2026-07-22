import BigInt
@testable import FibonacciCore
import XCTest

final class FibonacciEngineTests: XCTestCase {
    func testSequenceBoundariesAndKnownValues() {
        let expected: [BigInt] = [0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55]

        for (index, value) in expected.enumerated() {
            XCTAssertEqual(FibonacciEngine.value(at: UInt64(index)), value, "F(\(index))")
        }

        XCTAssertEqual(
            FibonacciEngine.value(at: 100),
            BigInt("354224848179261915075")
        )
    }

    func testLargeKnownValueRetainsExpectedDigitsAndSuffix() {
        let value = FibonacciEngine.value(at: 1_000).description

        XCTAssertEqual(value.count, 209)
        XCTAssertEqual(value.suffix(20), "76137795166849228875")
    }
}

final class RingArithmeticTests: XCTestCase {
    func testMultiplyMatchesQuadraticRingFormula() {
        let lhs = Zrt5(2, 3)
        let rhs = Zrt5(5, 7)
        let product = lhs.multiply(rhs)

        XCTAssertEqual(product.a, 115)
        XCTAssertEqual(product.b, 29)
    }

    func testSquareMatchesQuadraticRingFormula() {
        let value = Zrt5(4, 3).square()

        XCTAssertEqual(value.a, 61)
        XCTAssertEqual(value.b, 24)
    }
}

final class LargeIntegerTransformTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FFTMultiplier.setBackendPreference(.vDSP)
    }

    func testVDSPMultiplyMatchesBigIntForSignedLargeOperands() {
        let lhs = (BigInt(1) << 1_800) + 0x1234_5678
        let rhs = (BigInt(1) << 1_700) + 0x7654_3210
        let expected = -(lhs * rhs)

        XCTAssertEqual(FFTMultiplier.multiply(lhs, -rhs), expected)
        XCTAssertEqual(FFTMultiplier.telemetrySnapshot().activeBackend, .vDSP)
    }

    func testVDSPSquareMatchesBigIntForLargeOperand() {
        let value = (BigInt(1) << 1_600) + 0x1234_5678

        XCTAssertEqual(FFTMultiplier.square(value), value * value)
        XCTAssertEqual(FFTMultiplier.telemetrySnapshot().activeBackend, .vDSP)
    }

    func testNTTMultiplyAndSquareMatchBigIntAboveTransformThreshold() {
        let lhs = (BigInt(1) << 4_200) + 0x1234_5678
        let rhs = (BigInt(1) << 4_100) + 0x7654_3210

        XCTAssertEqual(NTTMultiplier.multiply(lhs, rhs), lhs * rhs)
        XCTAssertEqual(NTTMultiplier.square(lhs), lhs * lhs)
    }
}
