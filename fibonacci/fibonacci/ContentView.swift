//
//  ContentView.swift
//  fibonacci
//
//  Maximum F(n) in 1 Second — Liquid Glass UI
//

import SwiftUI
import Charts
import BigInt
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ContentView: View {
    // With @Observable, we use @State to hold the instance, but observation happens automatically
    // when we access properties in the body
    @State private var viewModel = FibonacciViewModel()
    @State private var buttonScale: CGFloat = 1.0
    
    // Force observation by accessing viewModel properties in body
    // This ensures @Observable changes trigger view updates
    private var observedState: FibonacciViewModel.State { viewModel.state }
    private var observedCurrentN: UInt64 { viewModel.currentN }
    private var observedCurrentTimeMs: Double { viewModel.currentTimeMs }
    private var observedGraphDataCount: Int { viewModel.graphData.count }
    
    var body: some View {
        ZStack {
            backgroundView
            
            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 50)
                    
                    // Access viewModel.state directly to ensure observation
                    switch viewModel.state {
                    case .idle:
                        idleView
                    case .running:
                        runningView
                    case .completed:
                        completedView
                    }
                    
                    Spacer().frame(height: 40)
                }
                .padding(.horizontal, 24)
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 680)
        #endif
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Background
    
    private var backgroundView: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.06, blue: 0.1), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            RadialGradient(
                colors: [Color.accentColor.opacity(0.06), Color.clear],
                center: .top,
                startRadius: 40,
                endRadius: 350
            )
            .ignoresSafeArea()
        }
    }
    
    // MARK: - Idle
    
    private var idleView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 10) {
                Text("largest f(n) in 1 second")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 12)
            
            // Algorithm info
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ℤ√5 ring + fft")
                        .font(.headline)
                        .foregroundStyle(.white)
                    
                    Text("one shot o(log n) powering from base f(1,1)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineSpacing(2)
                }
            }
            
            startButton
            
            Text(viewModel.deviceInfo)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.25))
        }
    }
    
    private var startButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                buttonScale = 0.93
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) {
                    buttonScale = 1.0
                }
                viewModel.start()
            }
        }) {
            Text("run f(n)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 15)
                            .fill(.ultraThinMaterial)
                        
                        RoundedRectangle(cornerRadius: 15)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.65), Color.accentColor.opacity(0.35)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(.white.opacity(0.25), lineWidth: 1)
                    }
                )
                .shadow(color: Color.accentColor.opacity(0.35), radius: 16, y: 6)
        }
        .buttonStyle(.plain)
        .scaleEffect(buttonScale)
        #if os(macOS)
        .frame(maxWidth: 340)
        #endif
    }
    
    // MARK: - Running
    
    private var runningView: some View {
        VStack(spacing: 28) {
            // Current time display
            GlassCard {
                VStack(spacing: 6) {
                    Text("current time")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                    
                    Text("\(String(format: "%.3f", viewModel.currentTimeMs))ms")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
            }
            
            // Current n
            GlassCard {
                VStack(spacing: 6) {
                    Text("current n")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                    
                    Text(viewModel.currentN.formatted())
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                }
            }
            
            // Fibonacci number feed
            fibonacciFeedView
            
            // Real chart with optimizations
            if !viewModel.graphData.isEmpty {
                graphCard
            }
        }
    }
    
    // MARK: - Completed
    
    private var completedView: some View {
        VStack(spacing: 22) {
            // Success
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 65, height: 65)
                
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.green)
            }
            
            // Result card
            GlassCard {
                VStack(spacing: 18) {
                    VStack(spacing: 5) {
                        Text("maximum n")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white.opacity(0.45))
                            .tracking(0.8)
                        
                        Text("f(\(viewModel.maxN.formatted()))")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    
                    Divider().background(.white.opacity(0.1))
                    
                    HStack(spacing: 18) {
                        VStack(spacing: 3) {
                            Text("digits")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.45))
                            Text(viewModel.finalDigitCount.formatted())
                                .font(.headline)
                                .foregroundStyle(Color.accentColor)
                        }
                        
                        VStack(spacing: 3) {
                            Text(viewModel.finalTimeMs > 1010 ? "hardware limit" : "time")
                                .font(.caption2)
                                .foregroundStyle(viewModel.finalTimeMs > 1010 ? .red.opacity(0.7) : .white.opacity(0.45))
                            Text("\(String(format: "%.0f", viewModel.finalTimeMs)) ms")
                                .font(.headline)
                                .foregroundStyle(viewModel.finalTimeMs > 1010 ? .red : .white)
                        }
                    }
                }
            }
            
            if !viewModel.graphData.isEmpty {
                graphCard
            }
            
            numberPreview
            
            Button(action: { viewModel.reset() }) {
                Text("run again")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 150, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 11)
                            .fill(.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11)
                                    .stroke(.white.opacity(0.12), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Fibonacci Feed
    
    private var fibonacciFeedView: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("current fibonacci")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.8))
                
                ScrollView(.vertical, showsIndicators: false) {
                    if viewModel.currentFibonacci == 0 {
                        Text("computing...")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(viewModel.currentFibonacci.description)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }
    
    // MARK: - Graph
    
    private var graphCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("computation time vs n")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    if viewModel.maxN > 0 {
                        Text("n=\(formatScientific(viewModel.maxN))")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                
                if !viewModel.graphData.isEmpty {
                    // Calculate domain from graph data AND current values to prevent cutoff
                    let nValues = viewModel.graphData.map { Double($0.n) }
                    let timeValues = viewModel.graphData.map { $0.timeMs }
                    
                    // Include current max values to ensure domain always covers latest data
                    let minN = max(1.0, nValues.min() ?? 1.0) // Ensure >= 1 for log scale
                    let maxNFromGraph = nValues.max() ?? 1.0
                    let currentN = Double(viewModel.currentN)
                    let maxN = max(maxNFromGraph, currentN) // Use whichever is larger
                    
                    // Use fixed minimum for Y-axis to prevent bottom cutoff when early fast iterations get sampled out
                    let minTime = 0.001 // Fixed minimum for log scale stability
                    let maxTimeFromGraph = timeValues.max() ?? 1.0
                    let currentTime = viewModel.currentTimeMs
                    let maxTime = max(maxTimeFromGraph, currentTime) // Use whichever is larger
                    
                    Chart(viewModel.graphData) { point in
                        LineMark(
                            x: .value("n", point.n),
                            y: .value("time", point.timeMs)
                        )
                        .foregroundStyle(Color.accentColor)
                    }
                    .chartXScale(
                        domain: minN...maxN,
                        type: .log
                    )
                    .chartYScale(
                        domain: minTime...maxTime,
                        type: .log
                    )
                    .frame(height: 220)
                    .animation(.linear(duration: 0.1), value: viewModel.graphData.count)
                } else {
                    Rectangle()
                        .fill(.clear)
                        .frame(height: 220)
                }
            }
        }
    }
    
    private func formatScientific(_ n: UInt64) -> String {
        let d = Double(n)
        if d >= 1_000_000 {
            let exp = Int(log10(d))
            let mantissa = d / pow(10, Double(exp))
            return String(format: "%.2fe%d", mantissa, exp)
        } else if d >= 1_000 {
            return String(format: "%.0fk", d / 1_000)
        } else {
            return "\(n)"
        }
    }
    
    // MARK: - Number Preview
    
    private var numberPreview: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("result")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Button(action: copyResult) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                            Text("copy")
                        }
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }
                
                let fibStr = viewModel.finalFibonacci.description
                
                if fibStr.count < 100 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(fibStr)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(fibStr.prefix(50)) + "...")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.65))
                        Text("..." + String(fibStr.suffix(50)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func copyResult() {
        let text = viewModel.finalFibonacci.description
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Glass Card

struct GlassCard<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                    
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(0.025))
                    
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                }
            )
            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
    }
}

#Preview {
    ContentView()
}
