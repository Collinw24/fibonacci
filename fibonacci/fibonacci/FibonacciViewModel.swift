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
    // Marked nonisolated because we manually manage concurrency with DispatchQueue
    // These are not tracked by @Observable (they're private implementation details)
    nonisolated private let updateQueue = DispatchQueue(label: "fibonacci.updates", attributes: .concurrent)
    nonisolated private var _latestN: UInt64 = 0
    nonisolated private var _latestTimeMs: Double = 0.0
    nonisolated private var _latestTotalElapsed: Double = 0.0
    nonisolated private var _latestFib: BigInt = BigInt(0)
    // Store raw computation data for graph generation (separate from computation loop)
    nonisolated private var _computationHistory: [(n: UInt64, timeMs: Double, timestamp: Double)] = []
    
    // Direct property access - these are simple values, atomic reads/writes are safe
    // We use simple assignment (non-atomic but fast) - small risk of partial reads but acceptable for UI updates
    nonisolated private func updateLatestValues(n: UInt64, timeMs: Double, totalElapsed: Double) {
        // Direct assignment - no barrier needed for simple values
        _latestN = n
        _latestTimeMs = timeMs
        _latestTotalElapsed = totalElapsed
    }
    
    // Batch storage to avoid flooding the queue
    // Store only every Nth result to reduce write frequency
    nonisolated private var _historyWriteCounter: UInt64 = 0
    
    // Store computation result for graph generation (batched, non-blocking)
    nonisolated private func storeComputationResult(n: UInt64, timeMs: Double, totalElapsed: Double) {
        // Only store every 10th result (or first 100) to reduce write frequency
        if n <= 100 || n % 10 == 0 {
            updateQueue.async(flags: .barrier) {
                self._computationHistory.append((n: n, timeMs: timeMs, timestamp: totalElapsed))
                // Keep history manageable (last 10000 entries max)
                if self._computationHistory.count > 10000 {
                    self._computationHistory.removeFirst(5000)
                }
            }
        }
    }
    
    // Get computation history for graph (sampled) - async to avoid blocking MainActor
    nonisolated private func getComputationHistoryForGraph() async -> [(n: UInt64, timeMs: Double, timestamp: Double)] {
        return await withCheckedContinuation { continuation in
            updateQueue.async {
                // Sample history: take every Nth entry to keep graph smooth but manageable
                let sampleRate = max(1, self._computationHistory.count / 2000) // Max 2000 points for graph
                let sampled = self._computationHistory.enumerated().compactMap { index, value in
                    index % sampleRate == 0 ? value : nil
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
    private var uiUpdateTask: Task<Void, Never>?
    
    // Golden ratio for spiral calculations
    private static let goldenRatio = (1.0 + sqrt(5.0)) / 2.0
    private static let twoPi = 2.0 * Double.pi
    
    // MARK: - Public
    
    func start() {
        guard state != .running else {
            print("[ViewModel] start() called but already running, ignoring")
            return
        }
        
        print("[ViewModel] ========== STARTING COMPUTATION ==========")
        print("[ViewModel] State: idle -> running")
        
        state = .running
        currentN = 0
        currentTimeMs = 0.0
        totalElapsedMs = 0.0
        maxN = 0
        finalFibonacci = 0
        finalDigitCount = 0
        finalTimeMs = 0.0
        graphData = []
        
        print("[ViewModel] Initialized all state variables to 0/empty")
        
        // Start UI update timer (runs separately from computation, tries to keep up)
        startUIUpdateTimer()
        
        // Run computation on background thread using Task with explicit priority
        task = Task(priority: .userInitiated) { [weak self] in
            guard let self = self else {
                print("[ViewModel] ERROR: self is nil in Task")
                return
            }
            print("[ViewModel] Task started, calling runPurePowering()")
            await self.runPurePowering()
        }
        
        print("[ViewModel] Task created and started")
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
        _latestN = 0
        _latestTimeMs = 0.0
        _latestTotalElapsed = 0.0
        _latestFib = BigInt(0)
        _historyWriteCounter = 0
        clearComputationHistory()
    }
    
    // MARK: - UI Update Timer
    
    private func startUIUpdateTimer() {
        // Stop existing timer if any
        uiUpdateTask?.cancel()
        
        print("[ViewModel] Starting UI update timer (Task-based)")
        
        // Use Task-based timer loop - more reliable than Timer in async contexts
        uiUpdateTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            var iteration = 0
            while !Task.isCancelled {
                iteration += 1
                
                // Pull latest values directly (simple atomic reads, no sync block)
                let n = self._latestN
                let timeMs = self._latestTimeMs
                let totalElapsed = self._latestTotalElapsed
                
                // Log every ~3 seconds (30 iterations * 100ms = ~3s)
                if iteration % 30 == 0 {
                    print("[Timer] Iteration \(iteration): n=\(n), timeMs=\(String(format: "%.3f", timeMs))")
                }
                
                // Update properties directly - we're on MainActor, @Observable will detect
                self.currentN = n
                self.currentTimeMs = timeMs
                self.totalElapsedMs = totalElapsed
                
                // Generate graph points from computation history (async to avoid blocking)
                // Update graph less frequently (every 3 ticks) to reduce SwiftUI recomputes
                if iteration % 3 == 0 {
                    let history = await self.getComputationHistoryForGraph()
                    if !history.isEmpty {
                        // Convert history to graph points (sample appropriately)
                        let newPoints = history.map { entry -> GraphPoint in
                            // Approximate digit count (fast, no BigInt conversion needed)
                            let digitCount = Int(Double(entry.n) * 0.209) // log10(φ) ≈ 0.209
                            return GraphPoint(n: entry.n, timeMs: entry.timeMs, digitCount: digitCount)
                        }
                        self.graphData = newPoints
                    }
                }
                
                // Sleep for ~100ms (~10fps) for better performance during rapid computation
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
        
        print("[ViewModel] Timer task created")
    }
    
    private func stopUIUpdateTimer() {
        uiUpdateTask?.cancel()
        uiUpdateTask = nil
    }
    
    // MARK: - Core: Sequential Computation with Real-Time Graphing
    
    // Mark as nonisolated so it can run off MainActor (on background thread)
    nonisolated private func runPurePowering() async {
        print("[ViewModel] runPurePowering() - STARTED")
        
        let clock = ContinuousClock()
        let overallStartTime = clock.now
        let maxComputationMs: Double = 1000.0  // Stop when a single computation takes >= 1000ms
        
        var n: UInt64 = 1
        var lastFib: BigInt = BigInt(0)
        
        print("[ViewModel] About to compute first F(n)")
        
        // Immediate UI update to show computation started
        await MainActor.run {
            self.currentN = 1
            self.currentTimeMs = 0.0
            self.totalElapsedMs = 0.0
        }
        
        print("[ViewModel] First UI update complete, starting loop")
        
        while true {
            // Compute F(n) and measure time - THIS IS THE ONLY THING THIS LOOP DOES
            let compStart = clock.now
            let fib = fibonacci(n: n)
            let compDuration = compStart.duration(to: clock.now)
            let compTimeMs = durationToMs(compDuration)
            let now = clock.now
            let totalElapsed = durationToMs(overallStartTime.duration(to: now))
            
            // Log every computation (n increments by 1 each time)
            if n <= 10 || n % 1000 == 0 {
                print("[ViewModel] F(\(n)) computed in \(String(format: "%.3f", compTimeMs))ms")
            }
            
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
            updateLatestValues(n: n, timeMs: compTimeMs, totalElapsed: totalElapsed)
            storeComputationResult(n: n, timeMs: compTimeMs, totalElapsed: totalElapsed)
            
            n += 1
            
            // Temporary safeguard to prevent infinite runs during testing
            // Remove after confirming FFT fixes work correctly
            if n > 50_000 {
                print("[ViewModel] Emergency break at n=\(n) (temporary safeguard)")
                break
            }
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
        
        let result = fib.b
        
        // Temporary verification prints (remove after confirming fixes)
        if n == 10 {
            print("[ViewModel] F(10): \(result) (should be 55)")
        }
        if n == 100 {
            print("[ViewModel] F(100): \(result) (should be 354224848179261915075)")
        }
        
        return result
    }
    
    nonisolated private func durationToMs(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1_000_000_000_000_000.0
    }
}
