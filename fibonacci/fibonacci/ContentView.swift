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
    @State private var viewModel = FibonacciViewModel()
    @State private var buttonScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            backgroundView

            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: Spacing.xxxl)

                    switch viewModel.state {
                    case .idle:
                        idleView
                    case .running:
                        runningView
                    case .completed:
                        completedView
                    }

                    Spacer().frame(height: Spacing.xxl)
                }
                .padding(.horizontal, Spacing.cardPadding + Spacing.xxxs)
            }
        }
        #if os(macOS)
        .frame(minWidth: Sizes.minWindowWidth, minHeight: Sizes.minWindowHeight)
        #endif
        .preferredColorScheme(.dark)
    }

    // MARK: - Background

    private var backgroundView: some View {
        ZStack {
            LinearGradient(
                colors: [Colors.backgroundTop, Colors.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [Colors.accentGlow, Colors.clear],
                center: .top,
                startRadius: Spacing.xxl,
                endRadius: 350
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: Spacing.xl) {
            VStack(spacing: Spacing.xxs) {
                Text("largest f(n) in 1 second")
                    .font(Typography.displayLarge)
                    .foregroundStyle(Colors.textPrimary)
            }
            .padding(.bottom, Spacing.xs)

            GlassCard {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("ℤ√5 ring + fft")
                        .font(Typography.bodyLarge)
                        .foregroundStyle(Colors.textPrimary)

                    Text("one shot o(log n) powering from base f(1,1)")
                        .font(Typography.bodyMedium)
                        .foregroundStyle(Colors.textSecondary)
                        .lineSpacing(2)
                }
            }

            modeSelector

            startButton

            verifyButton

            Text(viewModel.deviceInfo)
                .font(Typography.bodySmall)
                .foregroundStyle(Colors.textMuted)
        }
    }

    private var verifyButton: some View {
        Button(action: { viewModel.runVerification() }) {
            HStack(spacing: Spacing.xs) {
                if !viewModel.verificationMessage.isEmpty {
                    Image(systemName: viewModel.isVerified ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(viewModel.isVerified ? Colors.success : Colors.error)
                }
                Text(viewModel.verificationMessage.isEmpty ? "verify algorithm" : viewModel.verificationMessage)
                    .font(Typography.caption)
                    .foregroundStyle(viewModel.verificationMessage.isEmpty ? Colors.textMuted : (viewModel.isVerified ? Colors.success : Colors.error))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private var modeSelector: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("run mode")
                    .font(Typography.bodySmall)
                    .foregroundStyle(Colors.textTertiary)

                Picker("Mode", selection: $viewModel.runMode) {
                    Text("iterative").tag(FibonacciViewModel.RunMode.iterative)
                    Text("find max").tag(FibonacciViewModel.RunMode.findMax)
                }
                .pickerStyle(.segmented)

                Text(viewModel.runMode == .iterative
                     ? "test every n sequentially — watch the race"
                     : "binary search for largest f(n) < 1 second")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textMuted)
            }
        }
    }

    private var startButton: some View {
        Button(action: {
            withAnimation(Animations.buttonPress) {
                buttonScale = Animations.buttonScalePressed
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Animations.buttonDelay) {
                withAnimation(Animations.buttonRelease) {
                    buttonScale = 1.0
                }
                viewModel.start()
            }
        }) {
            Text("run f(n)")
                .font(Typography.titleMedium)
                .foregroundStyle(Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: Sizes.buttonHeight)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: Radii.button)
                            .fill(.ultraThinMaterial)

                        RoundedRectangle(cornerRadius: Radii.button)
                            .fill(
                                LinearGradient(
                                    colors: [Colors.accentGradientStart, Colors.accentGradientEnd],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        RoundedRectangle(cornerRadius: Radii.button)
                            .stroke(Colors.cardBorderHighlight, lineWidth: 1)
                    }
                )
                .shadow(color: Colors.accentShadow, radius: Shadows.buttonRadius, y: Shadows.buttonY)
        }
        .buttonStyle(.plain)
        .scaleEffect(buttonScale)
        .accessibilityLabel("Start Fibonacci computation")
        .accessibilityHint("Computes the largest Fibonacci number possible in one second")
        #if os(macOS)
        .frame(maxWidth: Sizes.buttonMaxWidth)
        #endif
    }

    // MARK: - Running

    private var runningView: some View {
        VStack(spacing: Spacing.lg) {
            if viewModel.runMode == .findMax && !viewModel.searchPhase.isEmpty {
                GlassCard {
                    VStack(spacing: Spacing.inline) {
                        Text(viewModel.searchPhase)
                            .font(Typography.bodySmall)
                            .foregroundStyle(Colors.accent)
                            .textCase(.lowercase)

                        if viewModel.searchLow > 0 || viewModel.searchHigh > 0 {
                            Text("\(viewModel.searchLow.formatted()) – \(viewModel.searchHigh.formatted())")
                                .font(Typography.caption)
                                .foregroundStyle(Colors.textMuted)
                                .monospacedDigit()
                        }
                    }
                }
            }

            GlassCard {
                VStack(spacing: Spacing.inline) {
                    Text("current time")
                        .font(Typography.bodySmall)
                        .foregroundStyle(Colors.textTertiary)

                    Text("\(String(format: "%.3f", viewModel.currentTimeMs))ms")
                        .font(Typography.headlineMedium)
                        .foregroundStyle(Colors.textPrimary)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current computation time: \(String(format: "%.3f", viewModel.currentTimeMs)) milliseconds")

            GlassCard {
                VStack(spacing: Spacing.inline) {
                    Text("current n")
                        .font(Typography.bodySmall)
                        .foregroundStyle(Colors.textTertiary)

                    Text(viewModel.currentN.formatted())
                        .font(Typography.headlineLarge)
                        .foregroundStyle(Colors.accent)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current n value: \(viewModel.currentN)")

            fibonacciFeedView

            if !viewModel.graphData.isEmpty {
                graphCard
            }
        }
    }

    // MARK: - Completed

    private var completedView: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Colors.successBackground)
                    .frame(width: Sizes.successIcon, height: Sizes.successIcon)

                Image(systemName: "checkmark")
                    .font(Typography.titleLarge)
                    .foregroundStyle(Colors.success)
            }
            .accessibilityLabel("Computation complete")

            GlassCard {
                VStack(spacing: Spacing.sm) {
                    VStack(spacing: Spacing.tight) {
                        Text("maximum n")
                            .font(Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Colors.textTertiary)
                            .tracking(0.8)

                        Text("f(\(viewModel.maxN.formatted()))")
                            .font(Typography.displayMedium)
                            .foregroundStyle(Colors.textPrimary)
                    }

                    Divider().background(Colors.divider)

                    HStack(spacing: Spacing.sm) {
                        VStack(spacing: Spacing.hair) {
                            Text("digits")
                                .font(Typography.caption)
                                .foregroundStyle(Colors.textTertiary)
                            Text(viewModel.finalDigitCount.formatted())
                                .font(Typography.bodyLarge)
                                .foregroundStyle(Colors.accent)
                        }

                        VStack(spacing: Spacing.hair) {
                            Text(viewModel.finalTimeMs > 1010 ? "hardware limit" : "time")
                                .font(Typography.caption)
                                .foregroundStyle(viewModel.finalTimeMs > 1010 ? Colors.errorMuted : Colors.textTertiary)
                            Text("\(String(format: "%.0f", viewModel.finalTimeMs)) ms")
                                .font(Typography.bodyLarge)
                                .foregroundStyle(viewModel.finalTimeMs > 1010 ? Colors.error : Colors.textPrimary)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Maximum n: \(viewModel.maxN), \(viewModel.finalDigitCount) digits, computed in \(String(format: "%.0f", viewModel.finalTimeMs)) milliseconds")

            GlassCard {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: viewModel.isVerified ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(viewModel.isVerified ? Colors.success : Colors.error)

                    Text(viewModel.isVerified ? "verified" : "unverified")
                        .font(Typography.bodySmall)
                        .foregroundStyle(viewModel.isVerified ? Colors.success : Colors.error)

                    Spacer()

                    Text(viewModel.verificationMessage)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textMuted)
                        .lineLimit(1)
                }
            }

            if !viewModel.graphData.isEmpty {
                graphCard
            }

            numberPreview

            Button(action: { viewModel.reset() }) {
                Text("run again")
                    .font(Typography.titleSmall)
                    .foregroundStyle(Colors.textPrimary)
                    .frame(width: Sizes.resetButtonWidth, height: Sizes.buttonHeightSmall)
                    .background(
                        RoundedRectangle(cornerRadius: Radii.buttonSmall)
                            .fill(Colors.buttonBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: Radii.buttonSmall)
                                    .stroke(Colors.buttonBorder, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Run computation again")
        }
    }

    // MARK: - Fibonacci Feed

    private var fibonacciFeedView: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("current fibonacci")
                    .font(Typography.bodyMedium)
                    .fontWeight(.medium)
                    .foregroundStyle(Colors.textSecondary)

                ScrollView(.vertical, showsIndicators: false) {
                    if viewModel.state == .running {
                        Text("~\(viewModel.estimatedDigitCount) digits...")
                            .font(Typography.codeLarge)
                            .foregroundStyle(Colors.textSecondary.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("ready")
                            .font(Typography.codeLarge)
                            .foregroundStyle(Colors.textSecondary.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: Sizes.feedMaxHeight)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current Fibonacci number being computed")
    }

    // MARK: - Graph

    private var graphCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text("computation time vs n")
                        .font(Typography.bodyMedium)
                        .fontWeight(.medium)
                        .foregroundStyle(Colors.textSecondary)
                    Spacer()
                    if viewModel.maxN > 0 {
                        Text("n=\(formatScientific(viewModel.maxN))")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textQuaternary)
                    }
                }

                let validData = viewModel.graphData.filter { $0.timeMs >= 0.001 }

                if validData.count >= 2 {
                    let nValues = validData.map { Double($0.n) }
                    let timeValues = validData.map { $0.timeMs }

                    let minN = max(1.0, nValues.min() ?? 1.0)
                    let maxN = max(nValues.max() ?? 1.0, Double(viewModel.currentN))

                    let minTime = max(0.001, timeValues.min() ?? 0.001)
                    let maxTime = max(timeValues.max() ?? 1.0, max(viewModel.currentTimeMs, minTime * 10))

                    Chart(validData) { point in
                        LineMark(
                            x: .value("n", point.n),
                            y: .value("time", point.timeMs)
                        )
                        .foregroundStyle(Colors.accent)
                    }
                    .chartXScale(domain: minN...maxN, type: .log)
                    .chartYScale(domain: minTime...maxTime, type: .log)
                    .frame(height: Sizes.graphHeight)
                    .animation(Animations.graphUpdate, value: validData.count)
                    .accessibilityLabel("Graph showing computation time versus n on logarithmic scales")
                } else {
                    Rectangle()
                        .fill(.clear)
                        .frame(height: Sizes.graphHeight)
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
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                HStack {
                    Text("result")
                        .font(Typography.bodySmall)
                        .foregroundStyle(Colors.textSecondary)
                    Spacer()
                    Button(action: copyResult) {
                        HStack(spacing: Spacing.hair) {
                            Image(systemName: "doc.on.doc")
                                .accessibilityHidden(true)
                            Text("copy")
                        }
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy Fibonacci result to clipboard")
                }

                // Skip string conversion for very large numbers (would freeze UI)
                if viewModel.finalDigitCount > 100000 {
                    Text("\(viewModel.finalDigitCount.formatted()) digits")
                        .font(Typography.codeSmall)
                        .foregroundStyle(Colors.textSecondary.opacity(0.8))
                    Text("(too large to display)")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textMuted)
                } else {
                    let fibStr = viewModel.finalFibonacci.description

                    if fibStr.count < 100 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(fibStr)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Colors.textSecondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: Spacing.micro) {
                            Text(String(fibStr.prefix(50)) + "...")
                                .font(Typography.codeSmall)
                                .foregroundStyle(Colors.textSecondary)
                            Text("..." + String(fibStr.suffix(50)))
                                .font(Typography.codeSmall)
                                .foregroundStyle(Colors.textSecondary)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fibonacci result with \(viewModel.finalDigitCount) digits")
    }

    // MARK: - Helpers

    private func copyResult() {
        // Skip copy for very large numbers
        if viewModel.finalDigitCount > 100000 {
            return
        }
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
            .padding(Spacing.cardPadding)
            .frame(maxWidth: .infinity)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: Radii.card)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)

                    RoundedRectangle(cornerRadius: Radii.card)
                        .fill(Colors.cardOverlay)

                    RoundedRectangle(cornerRadius: Radii.card)
                        .stroke(Colors.cardBorder, lineWidth: 1)
                }
            )
            .shadow(color: Colors.shadowDark, radius: Shadows.cardRadius, y: Shadows.cardY)
    }
}

#Preview {
    ContentView()
}
