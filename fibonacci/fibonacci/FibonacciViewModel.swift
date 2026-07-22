//
//  FibonacciViewModel.swift
//  fibonacci
//
//  Benchmark orchestration, timing, and live observation state.
//

import Foundation
import BigInt
import Observation
import Combine
import os

// Thread-safe update packet - all values updated atomically
private struct UpdatePacket: Sendable {
    nonisolated init() {}
    nonisolated init(n: UInt64, timeMs: Double, totalElapsed: Double, phase: String, low: UInt64, high: UInt64) {
        self.n = n
        self.timeMs = timeMs
        self.totalElapsed = totalElapsed
        self.phase = phase
        self.low = low
        self.high = high
    }
    nonisolated var n: UInt64 = 0
    nonisolated var timeMs: Double = 0.0
    nonisolated var totalElapsed: Double = 0.0
    nonisolated var phase: String = ""
    nonisolated var low: UInt64 = 0
    nonisolated var high: UInt64 = 0
}
/// Pure ring exponentiation with deterministic predictive stopping
/// Use @MainActor to ensure UI property updates work correctly with @Observable
@MainActor
@Observable
final class FibonacciViewModel {
    
    enum State {
        case idle
        case running
        case completed
    }

    enum RunMode {
        case iterative
        case findMax
    }

    var state: State = .idle
    var runMode: RunMode = .iterative
    var backendPreference: TransformBackendPreference = .automatic
    var transformTelemetry = FFTMultiplier.telemetrySnapshot()
    
    // Progress
    var currentN: UInt64 = 0
    var currentTimeMs: Double = 0.0
    var totalElapsedMs: Double = 0.0
    
    // Results
    var maxN: UInt64 = 0
    var finalFibonacci: BigInt = 0
    var finalDigitCount: Int = 0
    var finalTimeMs: Double = 0.0

    // Find-max mode status
    var searchPhase: String = ""
    var searchLow: UInt64 = 0
    var searchHigh: UInt64 = 0

    // Verification status
    var isVerified: Bool = false
    var verificationMessage: String = ""

    nonisolated private static let log10Phi = 0.20898  // log10(φ) for digit estimation: digits ≈ n * log10(φ)

    nonisolated private static let knownValues: [(n: UInt64, last20: String, digitCount: Int)] = [
        (n: 100, last20: "354224848179261915075", digitCount: 21),
        (n: 1000, last20: "76137795166849228875", digitCount: 209),
        (n: 10000, last20: "66073310059947366875", digitCount: 2090)
    ]
    
    // Graph data: n vs computation time
    struct GraphPoint: Identifiable {
        var id: UInt64 { n }
        let n: UInt64
        let timeMs: Double
        let digitCount: Int
    }
    
    var graphData: [GraphPoint] = []
    

    // Thread-safe storage using os_unfair_lock for minimal overhead
    @ObservationIgnored nonisolated private let updateLock = OSAllocatedUnfairLock(initialState: UpdatePacket())
    @ObservationIgnored nonisolated private let historyLock = OSAllocatedUnfairLock(initialState: [(n: UInt64, timeMs: Double, timestamp: Double)]())

    nonisolated private func updateLatestValues(n: UInt64, timeMs: Double, totalElapsed: Double) {
        updateLock.withLock { state in
            state.n = n
            state.timeMs = timeMs
            state.totalElapsed = totalElapsed
        }
    }

    // Write update packet with search status (for find-max mode)
    nonisolated private func updateSearchStatus(n: UInt64, timeMs: Double, totalElapsed: Double, phase: String, low: UInt64, high: UInt64) {
        updateLock.withLock { state in
            state.n = n
            state.timeMs = timeMs
            state.totalElapsed = totalElapsed
            state.phase = phase
            state.low = low
            state.high = high
        }
    }

    // Read update packet (called from main thread)
    private func readLatestValues() -> UpdatePacket {
        updateLock.withLock { $0 }
    }
    
    // Counter for graph update throttling
    @ObservationIgnored nonisolated(unsafe) private var _updateCounter: Int = 0
    
    // Store computation result for graph generation (adaptive frequency)
    nonisolated private func storeComputationResult(n: UInt64, timeMs: Double, totalElapsed: Double) {
        // Adaptive storage: dense early, sparse later
        let shouldStore = n <= 1000 ||
                         (n <= 10_000 && n % 10 == 0) ||
                         (n <= 100_000 && n % 100 == 0) ||
                         (n % 1000 == 0)
        if shouldStore {
            historyLock.withLock { history in
                history.append((n: n, timeMs: timeMs, timestamp: totalElapsed))
                // Keep history manageable but preserve early data
                if history.count > 20000 {
                    let earlyData = Array(history.prefix(1000))
                    let recentData = Array(history.suffix(19000))
                    var combined = earlyData
                    let earlyMaxN = earlyData.last?.n ?? 0
                    for entry in recentData {
                        if entry.n > earlyMaxN {
                            combined.append(entry)
                        }
                    }
                    history = combined
                }
            }
        }
    }

    // Get computation history for graph (sampled) - synchronous for speed
    nonisolated private func getComputationHistoryForGraph() -> [(n: UInt64, timeMs: Double, timestamp: Double)] {
        let history = historyLock.withLock { $0 }
        guard !history.isEmpty else { return [] }

        // Smart sampling: preserve points across the full range to prevent data loss
        let targetPoints = 1000
        let count = history.count

        var sampled: [(n: UInt64, timeMs: Double, timestamp: Double)] = []

        if count <= targetPoints {
            sampled = history
        } else {
            // Always preserve first 100 entries (early iterations are critical for graph shape)
            let earlyCount = min(100, count / 10)
            sampled.append(contentsOf: Array(history.prefix(earlyCount)))

            // Sample middle section (every Nth entry)
            let remainingNeeded = targetPoints - sampled.count - 1 // -1 for last entry
            let middleStart = earlyCount
            let middleEnd = count - 1
            let middleRange = middleEnd - middleStart

            if middleRange > 0 && remainingNeeded > 0 {
                let middleStep = max(1, middleRange / remainingNeeded)
                for i in stride(from: middleStart, to: middleEnd, by: middleStep) {
                    sampled.append(history[i])
                }
            }

            // Always include the last entry
            if count > 1 && sampled.last?.n != history[count - 1].n {
                sampled.append(history[count - 1])
            }
        }

        return sampled
    }

    private func clearComputationHistory() {
        historyLock.withLock { history in
            history.removeAll()
        }
    }


    var deviceInfo: String {
        #if os(macOS)
        return "macos • apple silicon"
        #else
        return "ios • apple silicon"
        #endif
    }

    var estimatedDigitCount: Int {
        Int(Double(currentN) * Self.log10Phi)
    }
    
    private var task: Task<Void, Never>?
    private var updateCancellable: AnyCancellable?

    // MARK: - Public
    
    func start() {
        guard state != .running else { return }

        FFTMultiplier.setBackendPreference(backendPreference)
        transformTelemetry = FFTMultiplier.telemetrySnapshot()
        state = .running
        currentN = 0
        currentTimeMs = 0.0
        totalElapsedMs = 0.0
        maxN = 0
        finalFibonacci = 0
        finalDigitCount = 0
        finalTimeMs = 0.0
        graphData = []
        searchPhase = ""
        searchLow = 0
        searchHigh = 0

        // Start UI update timer (runs separately from computation)
        startUIUpdateTimer()

        // Run computation on background thread using Task.detached to force background executor
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            switch await self.runMode {
            case .iterative:
                await self.runPurePowering()
            case .findMax:
                await self.runFindMax()
            }
        }
    }
    
    func reset() {
        task?.cancel()
        stopUIUpdateTimer()
        state = .idle
        currentN = 0
        currentTimeMs = 0.0
        totalElapsedMs = 0.0
        maxN = 0
        finalFibonacci = 0
        finalDigitCount = 0
        finalTimeMs = 0.0
        graphData = []
        updateLock.withLock { state in
            state.n = 0
            state.timeMs = 0.0
            state.totalElapsed = 0.0
        }
        _lastDisplayedN = 0
        clearComputationHistory()
    }
    
    // MARK: - UI Update Timer (60Hz for stability)

    private func startUIUpdateTimer() {
        stopUIUpdateTimer()

        _updateCounter = 0
        _lastDisplayedN = 0
        updateCancellable = Timer.publish(every: 1.0/60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.state == .running else { return }

                let packet = self.readLatestValues()
                self._updateCounter += 1

                if self._updateCounter.isMultiple(of: 6) {
                    self.refreshGraphData()
                    self.transformTelemetry = FFTMultiplier.telemetrySnapshot()
                }
                guard packet.n != self._lastDisplayedN else { return }
                self._lastDisplayedN = packet.n

                self.currentN = packet.n
                self.currentTimeMs = packet.timeMs
                self.totalElapsedMs = packet.totalElapsed
                self.searchPhase = packet.phase
                self.searchLow = packet.low
                self.searchHigh = packet.high

            }
    }

    @ObservationIgnored private var _lastDisplayedN: UInt64 = 0
    
    private func refreshGraphData() {
        graphData = getComputationHistoryForGraph().map { entry in
            GraphPoint(
                n: entry.n,
                timeMs: entry.timeMs,
                digitCount: Int(Double(entry.n) * Self.log10Phi)
            )
        }
    }

    private func stopUIUpdateTimer() {
        updateCancellable?.cancel()
        updateCancellable = nil
    }
    
    // MARK: - Core: Sequential Computation with Real-Time Graphing
    
    // Mark as nonisolated so it can run off MainActor (on background thread)
    nonisolated private func runPurePowering() async {
        let clock = ContinuousClock()
        let overallStartTime = clock.now
        let maxComputationMs: Double = 1000.0  // Stop when a single computation takes >= 1000ms
        
        var n: UInt64 = 1
        var lastFib: BigInt = BigInt(0)
        
        // Immediate UI update to show computation started
        await MainActor.run {
            self.currentN = 1
            self.currentTimeMs = 0.0
            self.totalElapsedMs = 0.0
        }
        
        while true {
            if Task.isCancelled { break }
            let compStart = clock.now
            let fib = FibonacciEngine.value(at: n)
            let compDuration = compStart.duration(to: clock.now)
            let compTimeMs = durationToMs(compDuration)
            let now = clock.now
            let totalElapsed = durationToMs(overallStartTime.duration(to: now))
            
            // Check if this computation took too long BEFORE storing it
            if compTimeMs >= maxComputationMs {
                // This computation took too long, so n-1 was the last valid one
                break
            }
            
            // Store this as the last valid result (only if it didn't take too long)
            lastFib = fib
            
            updateLatestValues(n: n, timeMs: compTimeMs, totalElapsed: totalElapsed)
            storeComputationResult(n: n, timeMs: compTimeMs, totalElapsed: totalElapsed)
            
            n += 1
            
        }
        
        // Final results - n is the one that took too long, so n-1 is the last valid
        let finalN = n > 0 ? n - 1 : 0
        let finalFib = lastFib  // Capture to avoid concurrency warning
        let finalDigitCount = Int(Double(finalFib.magnitude.bitWidth) * 0.30103)
        
        // Final UI sync on MainActor
        // Get history before entering MainActor (async call)
        let finalHistory = getComputationHistoryForGraph()
        
        // Verify the final result
        let verification = verifyResult(n: finalN, fib: finalFib)

        await MainActor.run {
            self.stopUIUpdateTimer()

            self.graphData = finalHistory.map { entry in
                let digitCount = Int(Double(entry.n) * Self.log10Phi)
                return GraphPoint(n: entry.n, timeMs: entry.timeMs, digitCount: digitCount)
            }

            self.maxN = finalN
            self.finalFibonacci = finalFib
            self.finalDigitCount = finalDigitCount
            self.finalTimeMs = finalHistory.last?.timeMs ?? 0.0
            self.isVerified = verification.passed
            self.verificationMessage = verification.message
            self.transformTelemetry = FFTMultiplier.telemetrySnapshot()
            self.state = .completed
        }
    }

    // MARK: - Find Max Mode: Binary Search for Largest F(n) in 1 Second

    nonisolated private func runFindMax() async {
        let clock = ContinuousClock()
        let overallStartTime = clock.now
        let targetMs: Double = 1000.0

        // Phase 1: Exponential probing to find upper bound
        var low: UInt64 = 1
        var high: UInt64 = 1
        var lastGoodN: UInt64 = 1
        var lastGoodFib: BigInt = BigInt(1)
        var lastGoodTimeMs: Double = 0.0

        // Start with n=1000 and double until we exceed 1000ms
        var probeN: UInt64 = 1000

        while true {
            if Task.isCancelled { break }
            let totalElapsed = durationToMs(overallStartTime.duration(to: clock.now))
            updateSearchStatus(n: probeN, timeMs: 0, totalElapsed: totalElapsed, phase: "probing", low: 0, high: 0)

            let compStart = clock.now
            let fib = FibonacciEngine.value(at: probeN)
            let compTimeMs = durationToMs(compStart.duration(to: clock.now))

            storeComputationResult(n: probeN, timeMs: compTimeMs, totalElapsed: totalElapsed)

            if compTimeMs >= targetMs {
                high = probeN
                break
            }

            lastGoodN = probeN
            lastGoodFib = fib
            lastGoodTimeMs = compTimeMs
            low = probeN

            // Double the probe value
            probeN = probeN * 2
            if probeN > 100_000_000 {
                high = probeN
                break
            }
        }

        // Phase 2: Binary search between low and high - continue until range is small
        while high - low > 100 {
            if Task.isCancelled { break }
            let mid = low + (high - low) / 2
            let totalElapsed = durationToMs(overallStartTime.duration(to: clock.now))
            updateSearchStatus(n: mid, timeMs: 0, totalElapsed: totalElapsed, phase: "binary search", low: low, high: high)

            let compStart = clock.now
            let fib = FibonacciEngine.value(at: mid)
            let compTimeMs = durationToMs(compStart.duration(to: clock.now))

            storeComputationResult(n: mid, timeMs: compTimeMs, totalElapsed: totalElapsed)

            if compTimeMs >= targetMs {
                high = mid
            } else {
                low = mid
                lastGoodN = mid
                lastGoodFib = fib
                lastGoodTimeMs = compTimeMs
            }
        }

        // Phase 3: Push as close to 1000ms as possible
        // Keep incrementing until we exceed 1000ms, then back off
        var attempts = 0
        let maxAttempts = 20

        while lastGoodTimeMs < 990 && attempts < maxAttempts {
            if Task.isCancelled { break }
            attempts += 1

            // Estimate how much more n we can add based on current time
            // Time scales roughly as O(n * log(n)), so we can extrapolate
            let timeRatio = targetMs / max(lastGoodTimeMs, 1.0)
            let estimatedStep = UInt64(Double(lastGoodN) * (timeRatio - 1.0) * 0.3)
            let step = max(1, min(estimatedStep, 100000))

            let probeN = lastGoodN + step

            let totalElapsed = durationToMs(overallStartTime.duration(to: clock.now))
            updateSearchStatus(n: probeN, timeMs: 0, totalElapsed: totalElapsed, phase: "optimizing \(attempts)/\(maxAttempts)", low: lastGoodN, high: probeN + step)

            let compStart = clock.now
            let fib = FibonacciEngine.value(at: probeN)
            let compTimeMs = durationToMs(compStart.duration(to: clock.now))

            storeComputationResult(n: probeN, timeMs: compTimeMs, totalElapsed: totalElapsed)

            if compTimeMs >= targetMs {
                // Overshot - binary search between lastGoodN and probeN
                var lo = lastGoodN
                var hi = probeN
                while hi - lo > 1 {
                    if Task.isCancelled { break }
                    let mid = lo + (hi - lo) / 2
                    let midStart = clock.now
                    let midFib = FibonacciEngine.value(at: mid)
                    let midTime = durationToMs(midStart.duration(to: clock.now))

                    if midTime >= targetMs {
                        hi = mid
                    } else {
                        lo = mid
                        if midTime > lastGoodTimeMs {
                            lastGoodN = mid
                            lastGoodFib = midFib
                            lastGoodTimeMs = midTime
                        }
                    }
                }
                break
            }

            lastGoodN = probeN
            lastGoodFib = fib
            lastGoodTimeMs = compTimeMs
        }

        // Final results - capture all values before MainActor block
        let finalN = lastGoodN
        let finalFib = lastGoodFib
        let finalTime = lastGoodTimeMs
        let finalDigitCount = Int(Double(finalFib.magnitude.bitWidth) * 0.30103)
        let finalHistory = getComputationHistoryForGraph()

        // Verify the final result
        let verification = verifyResult(n: finalN, fib: finalFib)

        await MainActor.run {
            self.stopUIUpdateTimer()

            self.graphData = finalHistory.map { entry in
                let digitCount = Int(Double(entry.n) * Self.log10Phi)
                return GraphPoint(n: entry.n, timeMs: entry.timeMs, digitCount: digitCount)
            }

            self.maxN = finalN
            self.finalFibonacci = finalFib
            self.finalDigitCount = finalDigitCount
            self.finalTimeMs = finalTime
            self.isVerified = verification.passed
            self.verificationMessage = verification.message
            self.transformTelemetry = FFTMultiplier.telemetrySnapshot()
            self.state = .completed
        }
    }

    
    nonisolated private func durationToMs(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1_000_000_000_000_000.0
    }

    // MARK: - Verification

    func runVerification() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let result = await self.performVerification()
            await MainActor.run {
                self.isVerified = result.passed
                self.verificationMessage = result.message
            }
        }
    }

    nonisolated private func performVerification() async -> (passed: Bool, message: String) {
        var allPassed = true
        var messages: [String] = []

        for test in Self.knownValues {
            let computed = FibonacciEngine.value(at: test.n)
            let computedStr = computed.description

            // Check digit count
            let expectedDigits = test.digitCount
            let actualDigits = computedStr.count
            let digitCountOK = actualDigits == expectedDigits

            // Check last digits
            let last20 = String(computedStr.suffix(20))
            let lastDigitsOK = last20 == test.last20 || computedStr == test.last20

            if digitCountOK && lastDigitsOK {
                messages.append("F(\(test.n)): ✓")
            } else {
                allPassed = false
                messages.append("F(\(test.n)): ✗ expected \(expectedDigits) digits ending \(test.last20), got \(actualDigits) digits ending \(last20)")
            }
        }

        let summary = allPassed ? "all tests passed" : "verification failed"
        return (allPassed, "\(summary) • \(messages.joined(separator: " "))")
    }

    nonisolated func verifyResult(n: UInt64, fib: BigInt) -> (passed: Bool, message: String) {
        // For very large numbers, use bit-based digit estimation to avoid slow string conversion
        let expectedDigits = Int(Double(n) * Self.log10Phi)

        if n > 100000 {
            // Use bitWidth to estimate digits: digits ≈ bitWidth * log10(2) ≈ bitWidth * 0.30103
            let estimatedDigits = Int(Double(fib.magnitude.bitWidth) * 0.30103)
            let digitCountOK = abs(estimatedDigits - expectedDigits) <= max(1, expectedDigits / 100)

            if !digitCountOK {
                return (false, "digit count mismatch: expected ~\(expectedDigits), got ~\(estimatedDigits)")
            }
            return (true, "~\(estimatedDigits) digits (estimated)")
        }

        // For smaller numbers, do full string verification
        let fibStr = fib.description
        let actualDigits = fibStr.count
        let digitCountOK = abs(actualDigits - expectedDigits) <= 1

        if !digitCountOK {
            return (false, "digit count mismatch: expected ~\(expectedDigits), got \(actualDigits)")
        }

        // For known values, verify last digits
        if let known = Self.knownValues.first(where: { $0.n == n }) {
            let last20 = String(fibStr.suffix(20))
            if last20 != known.last20 && fibStr != known.last20 {
                return (false, "last digits mismatch")
            }
        }

        return (true, "\(actualDigits) digits verified")
    }
}
