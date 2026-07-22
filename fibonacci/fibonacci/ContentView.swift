//
//  ContentView.swift
//  fibonacci
//
//  Interactive Apple silicon Fibonacci benchmark dashboard.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = FibonacciViewModel()
    @State private var buttonScale: CGFloat = 1
    @State private var selectedGraphX: Double?

    var body: some View {
        ZStack {
            backgroundView

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    header

                    switch viewModel.state {
                    case .idle:
                        idleView
                    case .running:
                        runningView
                    case .completed:
                        completedView
                    }
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, Spacing.cardPadding + Spacing.xxxs)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.xxl)
                .frame(maxWidth: .infinity)
            }
        }
        #if os(macOS)
        .frame(minWidth: Sizes.minWindowWidth, minHeight: Sizes.minWindowHeight)
        #endif
        .preferredColorScheme(.dark)
        .onChange(of: viewModel.state) { _, _ in
            selectedGraphX = nil
        }
    }

    private var backgroundView: some View {
        ZStack {
            LinearGradient(
                colors: [Colors.backgroundTop, Colors.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [Colors.accentGlow.opacity(1.8), Colors.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 480
            )
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Label("APPLE SILICON COMPUTE LAB", systemImage: "function")
                .font(Typography.caption)
                .fontWeight(.semibold)
                .tracking(1.4)
                .foregroundStyle(Colors.accent)

            Text("Fibonacci at the edge of a second.")
                .font(Typography.displayLarge)
                .foregroundStyle(Colors.textPrimary)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)

            Text("Explore exact integer arithmetic across Accelerate and Metal, then inspect where the hardware spends its time.")
                .font(Typography.bodyMedium)
                .foregroundStyle(Colors.textSecondary)
                .lineSpacing(3)
                .frame(maxWidth: 620, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: Spacing.md) {
            algorithmCard
            configurationCard
            backendStatusCard
            startButton
            verificationButton
        }
    }

    private var algorithmCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Spacing.micro) {
                        Text("Exact ring exponentiation")
                            .font(Typography.titleMedium)
                            .foregroundStyle(Colors.textPrimary)
                        Text("One-shot powering in ℤ[√5], with independently checked FFT reconstruction.")
                            .font(Typography.bodySmall)
                            .foregroundStyle(Colors.textSecondary)
                    }
                    Spacer(minLength: Spacing.xs)
                    Image(systemName: "sum")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Colors.accent)
                        .accessibilityHidden(true)
                }

                Divider().overlay(Colors.divider)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.xs) {
                        ValueTile(label: "POWERING", value: "O(log n)", tint: Colors.accent)
                        ValueTile(label: "INTEGER", value: "BigInt", tint: Colors.textPrimary)
                        ValueTile(label: "CHECK", value: "mod prime", tint: Colors.success)
                    }
                    VStack(spacing: Spacing.xs) {
                        ValueTile(label: "POWERING", value: "O(log n)", tint: Colors.accent)
                        ValueTile(label: "INTEGER", value: "BigInt", tint: Colors.textPrimary)
                        ValueTile(label: "CHECK", value: "mod prime", tint: Colors.success)
                    }
                }
            }
        }
    }

    private var configurationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                configurationSection(
                    title: "Search strategy",
                    detail: viewModel.runMode == .iterative
                        ? "Walk every index and reveal the growth curve live."
                        : "Probe, bracket, then converge on the one-second boundary."
                ) {
                    Picker("Search strategy", selection: $viewModel.runMode) {
                        Text("Iterative").tag(FibonacciViewModel.RunMode.iterative)
                        Text("Find max").tag(FibonacciViewModel.RunMode.findMax)
                    }
                    .pickerStyle(.segmented)
                }

                Divider().overlay(Colors.divider)

                configurationSection(title: "Transform backend", detail: backendPreferenceDetail) {
                    Picker("Transform backend", selection: $viewModel.backendPreference) {
                        ForEach(TransformBackendPreference.allCases) { backend in
                            Text(backend.shortTitle).tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .disabled(viewModel.state == .running)
    }

    private func configurationSection<Control: View>(
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Text(title)
                .font(Typography.bodySmall)
                .fontWeight(.semibold)
                .foregroundStyle(Colors.textTertiary)
            control()
            Text(detail)
                .font(Typography.caption)
                .foregroundStyle(Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var backendPreferenceDetail: String {
        switch viewModel.backendPreference {
        case .automatic:
            return FFTMultiplier.automaticBackendSummary + "."
        case .vDSP:
            return "Double-precision CPU FFT through Accelerate."
        case .mpsGraph:
            return viewModel.transformTelemetry.gpuAvailable
                ? "Experimental Float32 GPU FFT with adaptive radix and integrity-checked fallback."
                : "Metal is unavailable; computation will fall back to vDSP."
        }
    }

    private var startButton: some View {
        Button(action: startRun) {
            HStack(spacing: Spacing.xxxs) {
                Image(systemName: "play.fill")
                    .font(.caption)
                Text("Run benchmark")
                    .font(Typography.titleMedium)
            }
            .foregroundStyle(Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: Sizes.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: Radii.button)
                    .fill(
                        LinearGradient(
                            colors: [Colors.accentGradientStart, Colors.accentGradientEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Radii.button)
                            .stroke(Colors.cardBorderHighlight, lineWidth: 1)
                    }
            )
            .shadow(color: Colors.accentShadow, radius: Shadows.buttonRadius, y: Shadows.buttonY)
        }
        .buttonStyle(.plain)
        .scaleEffect(buttonScale)
        .accessibilityHint("Starts the selected exact Fibonacci benchmark")
    }

    private func startRun() {
        guard !reduceMotion else {
            viewModel.start()
            return
        }
        withAnimation(Animations.buttonPress) {
            buttonScale = Animations.buttonScalePressed
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Animations.buttonDelay) {
            withAnimation(Animations.buttonRelease) {
                buttonScale = 1
            }
            viewModel.start()
        }
    }

    private var verificationButton: some View {
        Button(action: { viewModel.runVerification() }) {
            HStack(spacing: Spacing.inline) {
                Image(systemName: viewModel.verificationMessage.isEmpty
                      ? "checkmark.shield"
                      : (viewModel.isVerified ? "checkmark.seal.fill" : "xmark.seal.fill"))
                Text(viewModel.verificationMessage.isEmpty ? "Verify known values" : viewModel.verificationMessage)
                    .lineLimit(2)
            }
            .font(Typography.caption)
            .foregroundStyle(verificationColor)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var verificationColor: Color {
        guard !viewModel.verificationMessage.isEmpty else { return Colors.textTertiary }
        return viewModel.isVerified ? Colors.success : Colors.error
    }

    // MARK: - Running

    private var runningView: some View {
        VStack(spacing: Spacing.md) {
            runStatusCard
            backendStatusCard
            graphCard
            fibonacciFeedView

            Button("Stop benchmark", role: .cancel) {
                viewModel.reset()
            }
            .font(Typography.bodySmall)
            .foregroundStyle(Colors.textTertiary)
            .buttonStyle(.plain)
        }
    }

    private var runStatusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Label(searchStatusTitle, systemImage: "waveform.path.ecg")
                        .font(Typography.bodySmall)
                        .fontWeight(.semibold)
                        .foregroundStyle(Colors.accent)
                    Spacer()
                    Text("LIVE")
                        .font(Typography.caption)
                        .fontWeight(.bold)
                        .tracking(1)
                        .foregroundStyle(Colors.success)
                        .padding(.horizontal, Spacing.xxxs)
                        .padding(.vertical, Spacing.micro)
                        .background(Capsule().fill(Colors.successBackground))
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .lastTextBaseline, spacing: Spacing.sm) {
                        primaryRunMetric
                        Spacer(minLength: Spacing.xs)
                        timeRunMetric
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        primaryRunMetric
                        timeRunMetric
                    }
                }

                Gauge(value: min(viewModel.currentTimeMs, 1000), in: 0...1000) {
                    Text("one-second limit")
                } currentValueLabel: {
                    Text("\(viewModel.currentTimeMs, format: .number.precision(.fractionLength(2))) ms")
                        .monospacedDigit()
                }
                .gaugeStyle(.linearCapacity)
                .tint(LinearGradient(colors: [Colors.accent, Colors.error], startPoint: .leading, endPoint: .trailing))
            }
        }
    }

    private var primaryRunMetric: some View {
        VStack(alignment: .leading, spacing: Spacing.micro) {
            Text("CURRENT INDEX")
                .font(Typography.caption)
                .tracking(0.9)
                .foregroundStyle(Colors.textMuted)
            Text("F(\(viewModel.currentN.formatted()))")
                .font(Typography.displayMedium)
                .foregroundStyle(Colors.textPrimary)
                .monospacedDigit()
                .minimumScaleFactor(0.65)
        }
    }

    private var timeRunMetric: some View {
        VStack(alignment: .leading, spacing: Spacing.micro) {
            Text("COMPUTE")
                .font(Typography.caption)
                .tracking(0.9)
                .foregroundStyle(Colors.textMuted)
            Text("\(viewModel.currentTimeMs, format: .number.precision(.fractionLength(3))) ms")
                .font(Typography.headlineMedium)
                .foregroundStyle(Colors.accent)
                .monospacedDigit()
        }
    }

    private var searchStatusTitle: String {
        if viewModel.runMode == .findMax, !viewModel.searchPhase.isEmpty {
            let range = viewModel.searchHigh > 0
                ? " · \(viewModel.searchLow.formatted())–\(viewModel.searchHigh.formatted())"
                : ""
            return viewModel.searchPhase.capitalized + range
        }
        return "Scanning exact results"
    }

    // MARK: - Completed

    private var completedView: some View {
        VStack(spacing: Spacing.md) {
            resultHeroCard
            verificationResultCard
            backendStatusCard
            graphCard
            numberPreview

            HStack(spacing: Spacing.xs) {
                Button("Run again") {
                    viewModel.reset()
                }
                .buttonStyle(.borderedProminent)

                Button("Copy result", action: copyResult)
                    .buttonStyle(.bordered)
                    .disabled(viewModel.finalDigitCount > 100_000)
            }
            .controlSize(.large)
        }
    }

    private var resultHeroCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label("Benchmark complete", systemImage: "checkmark.circle.fill")
                    .font(Typography.bodySmall)
                    .fontWeight(.semibold)
                    .foregroundStyle(Colors.success)

                Text("F(\(viewModel.maxN.formatted()))")
                    .font(Typography.displayLarge)
                    .foregroundStyle(Colors.textPrimary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.62)

                Text("Largest accepted result below the one-second computation boundary.")
                    .font(Typography.bodySmall)
                    .foregroundStyle(Colors.textSecondary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.xs) {
                        ValueTile(label: "DIGITS", value: viewModel.finalDigitCount.formatted(), tint: Colors.accent)
                        ValueTile(label: "COMPUTE", value: "\(viewModel.finalTimeMs.formatted(.number.precision(.fractionLength(1)))) ms", tint: Colors.textPrimary)
                        ValueTile(label: "POINTS", value: viewModel.graphData.count.formatted(), tint: Colors.textPrimary)
                    }
                    VStack(spacing: Spacing.xs) {
                        ValueTile(label: "DIGITS", value: viewModel.finalDigitCount.formatted(), tint: Colors.accent)
                        ValueTile(label: "COMPUTE", value: "\(viewModel.finalTimeMs.formatted(.number.precision(.fractionLength(1)))) ms", tint: Colors.textPrimary)
                    }
                }
            }
        }
    }

    private var verificationResultCard: some View {
        GlassCard {
            HStack(alignment: .top, spacing: Spacing.xxxs) {
                Image(systemName: viewModel.isVerified ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(viewModel.isVerified ? Colors.success : Colors.error)
                VStack(alignment: .leading, spacing: Spacing.micro) {
                    Text(viewModel.isVerified ? "Result verified" : "Verification failed")
                        .font(Typography.bodySmall)
                        .fontWeight(.semibold)
                        .foregroundStyle(viewModel.isVerified ? Colors.success : Colors.error)
                    Text(viewModel.verificationMessage)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textMuted)
                }
                Spacer()
            }
        }
    }

    // MARK: - Backend Telemetry

    private var backendStatusCard: some View {
        let telemetry = viewModel.transformTelemetry

        return GlassCard {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .center) {
                    Label("Compute path", systemImage: telemetry.activeBackend == .mpsGraph ? "gpu" : "cpu")
                        .font(Typography.bodySmall)
                        .fontWeight(.semibold)
                        .foregroundStyle(Colors.textSecondary)
                    Spacer()
                    Text(viewModel.deviceInfo)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textMuted)
                }

                HStack(spacing: Spacing.xxxs) {
                    Circle()
                        .fill(telemetry.activeBackend == .mpsGraph ? Colors.success : Colors.accent)
                        .frame(width: 7, height: 7)
                    Text(telemetry.activeBackend.title)
                        .font(Typography.titleMedium)
                        .foregroundStyle(Colors.textPrimary)
                    Spacer()
                    Text(telemetry.fftSize > 0 ? "\(formatCount(telemetry.fftSize)) bins" : "direct")
                        .font(Typography.codeLarge)
                        .foregroundStyle(Colors.textTertiary)
                }

                HStack(spacing: Spacing.xs) {
                    telemetryDatum("REQUESTED", viewModel.backendPreference.title)
                    telemetryDatum("WORKLOAD", telemetry.workloadBits > 0 ? "\(formatCount(telemetry.workloadBits)) bits" : "—")
                    telemetryDatum("FALLBACKS", telemetry.fallbackCount.formatted())
                }

                if viewModel.backendPreference == .mpsGraph {
                    Text(telemetry.gpuAvailable
                         ? "GPU results use a conservative Float32 radix and modular integrity check before acceptance."
                         : "No Metal device is available; vDSP is the safe fallback.")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func telemetryDatum(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Colors.textMuted)
            Text(value)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Live Number and Graph

    private var fibonacciFeedView: some View {
        GlassCard {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "textformat.123")
                    .font(.title3)
                    .foregroundStyle(Colors.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.micro) {
                    Text("Current magnitude")
                        .font(Typography.bodySmall)
                        .fontWeight(.semibold)
                        .foregroundStyle(Colors.textSecondary)
                    Text("Approximately \(viewModel.estimatedDigitCount.formatted()) decimal digits")
                        .font(Typography.codeLarge)
                        .foregroundStyle(Colors.textPrimary)
                        .monospacedDigit()
                }
                Spacer()
            }
        }
    }

    private var graphCard: some View {
        let validData = viewModel.graphData.filter { $0.n > 0 && $0.timeMs >= 0.001 }
        let selectedPoint = nearestPoint(in: validData)

        return GlassCard {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Spacing.micro) {
                        Text("Computation profile")
                            .font(Typography.titleMedium)
                            .foregroundStyle(Colors.textPrimary)
                        Text("Drag across the chart to inspect an exact sample.")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textMuted)
                    }
                    Spacer()
                    if let selectedPoint {
                        VStack(alignment: .trailing, spacing: Spacing.hair) {
                            Text("F(\(selectedPoint.n.formatted()))")
                                .font(Typography.caption)
                                .foregroundStyle(Colors.accent)
                            Text("\(selectedPoint.timeMs.formatted(.number.precision(.fractionLength(3)))) ms")
                                .font(Typography.codeLarge)
                                .foregroundStyle(Colors.textPrimary)
                        }
                    }
                }

                if validData.count >= 2 {
                    let minN = max(1, Double(validData.map(\.n).min() ?? 1))
                    let maxN = max(minN * 1.01, Double(validData.map(\.n).max() ?? 1))
                    let minTime = max(0.001, validData.map(\.timeMs).min() ?? 0.001)
                    let maxTime = max(1_200, (validData.map(\.timeMs).max() ?? 1) * 1.2)

                    Chart {
                        ForEach(validData) { point in
                            AreaMark(
                                x: .value("Index", Double(point.n)),
                                yStart: .value("Floor", minTime),
                                yEnd: .value("Time", point.timeMs)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Colors.accent.opacity(0.28), Colors.accent.opacity(0.01)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.monotone)

                            LineMark(
                                x: .value("Index", Double(point.n)),
                                y: .value("Time", point.timeMs)
                            )
                            .foregroundStyle(Colors.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                        }

                        RuleMark(y: .value("One second", 1000))
                            .foregroundStyle(Colors.errorMuted)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("1 s limit")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Colors.errorMuted)
                            }

                        if let selectedPoint {
                            RuleMark(x: .value("Selected", Double(selectedPoint.n)))
                                .foregroundStyle(Colors.textTertiary)
                            PointMark(
                                x: .value("Selected index", Double(selectedPoint.n)),
                                y: .value("Selected time", selectedPoint.timeMs)
                            )
                            .symbolSize(48)
                            .foregroundStyle(Colors.textPrimary)
                        }
                    }
                    .chartXScale(domain: minN...maxN, type: .log)
                    .chartYScale(domain: minTime...maxTime, type: .log)
                    .chartXAxisLabel("Fibonacci index", alignment: .center)
                    .chartYAxisLabel("Milliseconds")
                    .chartXSelection(value: $selectedGraphX)
                    .frame(height: Sizes.graphHeight + 40)
                    .animation(reduceMotion ? nil : Animations.graphUpdate, value: validData.count)
                    .accessibilityLabel("Interactive logarithmic chart of Fibonacci index and computation time")
                } else {
                    ContentUnavailableView {
                        Label("Waiting for samples", systemImage: "chart.xyaxis.line")
                    } description: {
                        Text("The live profile appears as the benchmark advances.")
                    }
                    .frame(height: Sizes.graphHeight)
                    .foregroundStyle(Colors.textMuted)
                }
            }
        }
    }

    private func nearestPoint(in points: [FibonacciViewModel.GraphPoint]) -> FibonacciViewModel.GraphPoint? {
        guard let selectedGraphX else { return nil }
        return points.min {
            abs(log(Double($0.n)) - log(selectedGraphX))
                < abs(log(Double($1.n)) - log(selectedGraphX))
        }
    }

    // MARK: - Number Preview

    private var numberPreview: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                HStack {
                    Text("Exact result")
                        .font(Typography.bodySmall)
                        .fontWeight(.semibold)
                        .foregroundStyle(Colors.textSecondary)
                    Spacer()
                    Text("\(viewModel.finalDigitCount.formatted()) digits")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textMuted)
                }

                if viewModel.finalDigitCount > 100_000 {
                    Text("The exact integer is retained in memory but omitted here to keep the interface responsive.")
                        .font(Typography.bodySmall)
                        .foregroundStyle(Colors.textTertiary)
                } else {
                    let value = viewModel.finalFibonacci.description
                    if value.count < 120 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(value)
                                .font(Typography.codeLarge)
                                .foregroundStyle(Colors.textSecondary)
                                .textSelection(.enabled)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: Spacing.micro) {
                            Text(String(value.prefix(58)) + "…")
                            Text("…" + String(value.suffix(58)))
                        }
                        .font(Typography.codeSmall)
                        .foregroundStyle(Colors.textSecondary)
                        .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatCount(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private func copyResult() {
        guard viewModel.finalDigitCount <= 100_000 else { return }
        let text = viewModel.finalFibonacci.description
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

private struct ValueTile: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.micro) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Colors.textMuted)
            Text(value)
                .font(Typography.bodyLarge)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(Spacing.xxxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radii.buttonSmall)
                .fill(Colors.buttonBackground.opacity(0.6))
        )
    }
}

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
