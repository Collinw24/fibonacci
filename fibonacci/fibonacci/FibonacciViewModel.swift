//
//  FibonacciViewModel.swift
//  fibonacci
//
//  Pure C++ spirit: O(log n) ring exponentiation
//  Single pass with deterministic predictive stopping
//

import Foundation
import BigInt
import Observation
import Combine

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
    
    var state: State = .idle
    
    // Progress
    var currentN: UInt64 = 0
    var currentTimeMs: Double = 0.0
    var totalElapsedMs: Double = 0.0
    var currentFibonacci: BigInt = 0
    
    // Results
    var maxN: UInt64 = 0
    var finalFibonacci: BigInt = 0
    var finalDigitCount: Int = 0
    var finalTimeMs: Double = 0.0
    
    // Graph data: n vs computation time
    struct GraphPoint: Identifiable {
        let id = UUID()
        let n: UInt64
        let timeMs: Double
        let digitCount: Int
    }
    
    var graphData: [GraphPoint] = []
    
    // Thread-safe storage for UI updates (non-blocking, lock-free)
    // Marked nonisolated(unsafe) because we manually manage concurrency with DispatchQueue
    // These are NOT tracked by @Observable - explicitly ignored to prevent macro expansion errors
    @ObservationIgnored nonisolated private let updateQueue = DispatchQueue(label: "fibonacci.updates", attributes: .concurrent)
    @ObservationIgnored nonisolated(unsafe) private var _latestN: UInt64 = 0
    @ObservationIgnored nonisolated(unsafe) private var _latestTimeMs: Double = 0.0
    @ObservationIgnored nonisolated(unsafe) private var _latestTotalElapsed: Double = 0.0
    @ObservationIgnored nonisolated(unsafe) private var _latestFib: BigInt = BigInt(0)
    @ObservationIgnored nonisolated(unsafe) private var _latestBitWidth: Int = 0
    // Store raw computation data for graph generation (separate from computation loop)
    @ObservationIgnored nonisolated(unsafe) private var _computationHistory: [(n: UInt64, timeMs: Double, timestamp: Double)] = []
    
    // Direct property access - these are simple values, atomic reads/writes are safe
    // We use simple assignment (non-atomic but fast) - small risk of partial reads but acceptable for UI updates
    nonisolated private func updateLatestValues(n: UInt64, timeMs: Double, totalElapsed: Double, fib: BigInt) {
        _latestN = n
        _latestTimeMs = timeMs
        _latestTotalElapsed = totalElapsed
        _latestBitWidth = fib.magnitude.bitWidth
        // Only store BigInt reference every 100 iterations to reduce copy overhead
        if n % 100 == 0 || n < 100 {
            _latestFib = fib
        }
    }
    
    // Batch storage to avoid flooding the queue
    // Store only every Nth result to reduce write frequency
    @ObservationIgnored nonisolated(unsafe) private var _historyWriteCounter: UInt64 = 0
    
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
            updateQueue.async(flags: .barrier) {
                self._computationHistory.append((n: n, timeMs: timeMs, timestamp: totalElapsed))
                // Keep history manageable but preserve early data
                // Increased limit to 20000 to delay trimming and preserve more early iterations
                if self._computationHistory.count > 20000 {
                    // Always preserve first 1000 entries (critical for graph shape at start)
                    // Then keep last 19000 entries (includes some overlap but ensures continuity)
                    let earlyData = Array(self._computationHistory.prefix(1000))
                    let recentData = Array(self._computationHistory.suffix(19000))
                    // Remove duplicates (entries that appear in both early and recent)
                    var combined = earlyData
                    let earlyMaxN = earlyData.last?.n ?? 0
                    for entry in recentData {
                        if entry.n > earlyMaxN {
                            combined.append(entry)
                        }
                    }
                    self._computationHistory = combined
                }
            }
        }
    }
    
    // Get computation history for graph (sampled) - async to avoid blocking MainActor
    nonisolated private func getComputationHistoryForGraph() async -> [(n: UInt64, timeMs: Double, timestamp: Double)] {
        return await withCheckedContinuation { continuation in
            updateQueue.async {
                guard !self._computationHistory.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                
                // Smart sampling: preserve points across the full range to prevent data loss
                // Take ~1000 points distributed across beginning, middle, and end
                let targetPoints = 1000
                let count = self._computationHistory.count
                
                var sampled: [(n: UInt64, timeMs: Double, timestamp: Double)] = []
                
                if count <= targetPoints {
                    // If we have fewer than target, include all
                    sampled = self._computationHistory
                } else {
                    // Always preserve first 100 entries (early iterations are critical for graph shape)
                    let earlyCount = min(100, count / 10)
                    sampled.append(contentsOf: Array(self._computationHistory.prefix(earlyCount)))
                    
                    // Sample middle section (every Nth entry)
                    let remainingNeeded = targetPoints - sampled.count - 1 // -1 for last entry
                    let middleStart = earlyCount
                    let middleEnd = count - 1
                    let middleRange = middleEnd - middleStart
                    
                    if middleRange > 0 && remainingNeeded > 0 {
                        let middleStep = max(1, middleRange / remainingNeeded)
                        for i in stride(from: middleStart, to: middleEnd, by: middleStep) {
                            sampled.append(self._computationHistory[i])
                        }
                    }
                    
                    // Always include the last entry
                    if count > 1 && sampled.last?.n != self._computationHistory[count - 1].n {
                        sampled.append(self._computationHistory[count - 1])
                    }
                }
                
                continuation.resume(returning: sampled)
            }
        }
    }
    
    private func clearComputationHistory() {
        updateQueue.async(flags: .barrier) {
            self._computationHistory.removeAll()
        }
    }
    
    var deviceInfo: String {
        #if os(macOS)
        return "macos • apple silicon"
        #else
        return "ios • apple silicon"
        #endif
    }
    
    private var task: Task<Void, Never>?
    private var updateCancellable: AnyCancellable?
    
    // Golden ratio for spiral calculations
    private static let goldenRatio = (1.0 + sqrt(5.0)) / 2.0
    private static let twoPi = 2.0 * Double.pi
    
    // MARK: - Public
    
    func start() {
        guard state != .running else { return }
        
        state = .running
        currentN = 0
        currentTimeMs = 0.0
        totalElapsedMs = 0.0
        currentFibonacci = 0
        maxN = 0
        finalFibonacci = 0
        finalDigitCount = 0
        finalTimeMs = 0.0
        graphData = []
        
        // Start UI update timer (runs separately from computation)
        startUIUpdateTimer()
        
        // Run computation on background thread using Task.detached to force background executor
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await self.runPurePowering()
        }
    }
    
    func reset() {
        task?.cancel()
        stopUIUpdateTimer()
        state = .idle
        currentN = 0
        currentTimeMs = 0.0
        totalElapsedMs = 0.0
        currentFibonacci = 0
        maxN = 0
        finalFibonacci = 0
        finalDigitCount = 0
        finalTimeMs = 0.0
        graphData = []
        _latestN = 0
        _latestTimeMs = 0.0
        _latestTotalElapsed = 0.0
        _latestFib = BigInt(0)
        _latestBitWidth = 0
        _lastDisplayedN = 0
        _historyWriteCounter = 0
        clearComputationHistory()
    }
    
    // MARK: - UI Update Timer (120Hz for ProMotion smoothness)

    private func startUIUpdateTimer() {
        stopUIUpdateTimer()

        // Update UI at 120Hz (~8.3ms) for ProMotion displays
        // This gives buttery smooth number updates during fast iterations
        _updateCounter = 0
        _lastDisplayedN = 0
        updateCancellable = Timer.publish(every: 1.0/120.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }

                guard self.state == .running else {
                    self.updateCancellable?.cancel()
                    self.updateCancellable = nil
                    return
                }

                let latestN = self._latestN

                // Skip update if n hasn't changed (avoids redundant UI work)
                guard latestN != self._lastDisplayedN else { return }
                self._lastDisplayedN = latestN

                // Update lightweight values only (no BigInt copy)
                self.currentN = latestN
                self.currentTimeMs = self._latestTimeMs
                self.totalElapsedMs = self._latestTotalElapsed

                self._updateCounter += 1

                // Update BigInt display every 120 frames (~1s) to reduce copy overhead
                // The BigInt is only stored every 100 iterations anyway
                if self._updateCounter % 120 == 0 {
                    self.currentFibonacci = self._latestFib
                }

                // Update graph every 240 frames (~2s)
                if self._updateCounter % 240 == 0 {
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let history = await self.getComputationHistoryForGraph()
                        if !history.isEmpty {
                            let newPoints = history.map { entry in
                                let digitCount = Int(Double(entry.n) * 0.209)
                                return GraphPoint(n: entry.n, timeMs: entry.timeMs, digitCount: digitCount)
                            }
                            self.graphData = newPoints
                        }
                    }
                }
            }
    }

    @ObservationIgnored private var _lastDisplayedN: UInt64 = 0
    
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
            // Compute F(n) and measure time - THIS IS THE ONLY THING THIS LOOP DOES
            let compStart = clock.now
            let fib = fibonacci(n: n)
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
            
            // Store values in thread-safe storage (non-blocking, very fast, no MainActor!)
            // Graph generation happens separately in the UI timer - NO graph logic here!
            // DON'T use await MainActor.run here - that would block the computation!
            // Just write to thread-safe storage, timer will read and update UI
            updateLatestValues(n: n, timeMs: compTimeMs, totalElapsed: totalElapsed, fib: fib)
            storeComputationResult(n: n, timeMs: compTimeMs, totalElapsed: totalElapsed)
            
            n += 1
            
        }
        
        // Final results - n is the one that took too long, so n-1 is the last valid
        let finalN = n > 0 ? n - 1 : 0
        let finalFib = lastFib  // Capture to avoid concurrency warning
        let finalDigitCount = Int(Double(finalFib.magnitude.bitWidth) * 0.30103)
        
        // Final UI sync on MainActor
        // Get history before entering MainActor (async call)
        let finalHistory = await getComputationHistoryForGraph()
        
        await MainActor.run {
            // Stop UI timer (on MainActor since method requires it)
            self.stopUIUpdateTimer()
            
            // Generate final graph from computation history
            self.graphData = finalHistory.map { entry in
                let digitCount = Int(Double(entry.n) * 0.209) // log10(φ) ≈ 0.209
                return GraphPoint(n: entry.n, timeMs: entry.timeMs, digitCount: digitCount)
            }
            
            // Final results
            self.maxN = finalN
            self.finalFibonacci = finalFib
            self.finalDigitCount = finalDigitCount
            self.finalTimeMs = finalHistory.last?.timeMs ?? 0.0
            self.state = .completed
        }
    }
    
    /// Compute F(n) using O(log n) ring exponentiation
    nonisolated private func fibonacci(n: UInt64) -> BigInt {
        if n == 0 { return BigInt(0) }
        if n <= 2 { return BigInt(1) }
        
        // Use the Zrt5 ring exponentiation method
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
    
    nonisolated private func durationToMs(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1_000_000_000_000_000.0
    }
}
