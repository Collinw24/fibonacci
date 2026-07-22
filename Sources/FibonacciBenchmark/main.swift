import FibonacciCore
import Foundation

private struct Options {
    var targetMilliseconds = 1_000.0
    var searchSamples = 3
    var finalSamples = 7
    var maximumIndex: UInt64 = 100_000_000
    var outputPath: String?

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0

        func value(after flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw BenchmarkError("Missing value after \(flag)")
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--target-ms":
                guard let value = Double(try value(after: argument)), value > 0 else {
                    throw BenchmarkError("--target-ms must be positive")
                }
                options.targetMilliseconds = value
            case "--search-samples":
                guard let value = Int(try value(after: argument)), value > 0 else {
                    throw BenchmarkError("--search-samples must be a positive integer")
                }
                options.searchSamples = value
            case "--final-samples":
                guard let value = Int(try value(after: argument)), value > 0 else {
                    throw BenchmarkError("--final-samples must be a positive integer")
                }
                options.finalSamples = value
            case "--max-index":
                guard let value = UInt64(try value(after: argument)), value > 0 else {
                    throw BenchmarkError("--max-index must be a positive integer")
                }
                options.maximumIndex = value
            case "--output":
                options.outputPath = try value(after: argument)
            case "--help", "-h":
                printUsage()
                exit(EXIT_SUCCESS)
            default:
                throw BenchmarkError("Unknown argument: \(argument)")
            }
            index += 1
        }

        return options
    }
}

private struct BenchmarkError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct Measurement: Codable {
    let index: UInt64
    let decimalDigits: Int?
    let timingsMilliseconds: [Double]
    let medianMilliseconds: Double
    let minimumMilliseconds: Double
    let maximumMilliseconds: Double
}

private struct Environment: Codable {
    let capturedAtUTC: String
    let hardware: String
    let operatingSystem: String
    let architecture: String
    let logicalProcessorCount: Int
    let physicalMemoryBytes: UInt64
    let buildConfiguration: String
    let sourceRevision: String
    let workingTreeDirty: Bool
}

private struct ProtocolRecord: Codable {
    let targetMilliseconds: Double
    let searchSamplesPerCandidate: Int
    let finalSamplesPerExample: Int
    let maximumIndex: UInt64
    let searchResolution: UInt64
    let backendPolicy: String
    let warmupIndex: UInt64
    let digitCountMethod: String
}

private enum BoundaryStatus: String, Codable {
    case observedRejection
    case maximumIndexReached
    case validationWindowExhausted
}

private struct Boundary: Codable {
    let status: BoundaryStatus
    let accepted: Measurement
    let firstRejected: Measurement?
}

private struct BenchmarkReport: Codable {
    let environment: Environment
    let protocolRecord: ProtocolRecord
    let boundary: Boundary
    let examples: [Measurement]
    let searchProbes: [Measurement]
}

private var resultSink = 0
private let clock = ContinuousClock()
private let log10Phi = Decimal(string: "0.20898764024997873376927208923755541682")!
private let log10SquareRootFive = Decimal(string: "0.34948500216800940239313055263775348662")!

private func decimalDigitCount(for index: UInt64) -> Int {
    guard index > 1 else { return 1 }
    var logarithm = Decimal(Int(index)) * log10Phi - log10SquareRootFive
    var integerPart = Decimal()
    NSDecimalRound(&integerPart, &logarithm, 0, .down)
    return NSDecimalNumber(decimal: integerPart).intValue + 1
}

private func durationMilliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func measure(index: UInt64, samples: Int, includeDigitCount: Bool) -> Measurement {
    var timings: [Double] = []
    timings.reserveCapacity(samples)
    let decimalDigits = includeDigitCount ? decimalDigitCount(for: index) : nil

    for sample in 0..<samples {
        let start = clock.now
        let value = FibonacciEngine.value(at: index)
        let elapsed = durationMilliseconds(start.duration(to: clock.now))
        timings.append(elapsed)
        resultSink ^= value.magnitude.bitWidth &+ sample

    }

    let sorted = timings.sorted()
    let midpoint = sorted.count / 2
    let median: Double
    if sorted.count.isMultiple(of: 2) {
        median = (sorted[midpoint - 1] + sorted[midpoint]) / 2
    } else {
        median = sorted[midpoint]
    }

    return Measurement(
        index: index,
        decimalDigits: decimalDigits,
        timingsMilliseconds: timings,
        medianMilliseconds: median,
        minimumMilliseconds: sorted.first ?? 0,
        maximumMilliseconds: sorted.last ?? 0
    )
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func recordProbe(
    index: UInt64,
    samples: Int,
    probes: inout [Measurement]
) -> Measurement {
    let measurement = measure(index: index, samples: samples, includeDigitCount: false)
    probes.append(measurement)
    log("probe F(\(index)): median \(format(measurement.medianMilliseconds)) ms")
    return measurement
}

private func format(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private func commandOutput(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return nil
    }
}

private func printUsage() {
    print("""
    Usage: swift run -c release fibonacci-benchmark [options]

      --target-ms <milliseconds>   Boundary target (default: 1000)
      --search-samples <count>    Samples per search candidate (default: 3)
      --final-samples <count>     Samples per reported example (default: 7)
      --max-index <index>         Search safety ceiling (default: 100000000)
      --output <path>             Write the complete benchmark report as JSON
    """)
}

private func environment() -> Environment {
    let revision = commandOutput("/usr/bin/git", ["rev-parse", "--short", "HEAD"]) ?? "unknown"
    let status = commandOutput("/usr/bin/git", ["status", "--porcelain"]) ?? ""

    #if DEBUG
    let configuration = "Debug"
    #else
    let configuration = "Release"
    #endif

    return Environment(
        capturedAtUTC: ISO8601DateFormatter().string(from: Date()),
        hardware: commandOutput("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]) ?? "unknown",
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: commandOutput("/usr/bin/uname", ["-m"]) ?? "unknown",
        logicalProcessorCount: ProcessInfo.processInfo.processorCount,
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
        buildConfiguration: configuration,
        sourceRevision: revision,
        workingTreeDirty: !status.isEmpty
    )
}

private func roundedRepresentativeIndex(_ boundary: UInt64, fraction: Double) -> UInt64 {
    let raw = UInt64(Double(boundary) * fraction)
    let quantum: UInt64 = boundary >= 100_000 ? 10_000 : 1_000
    return max(1, ((raw + quantum / 2) / quantum) * quantum)
}

private func run(_ options: Options) throws -> BenchmarkReport {
    let warmupIndex: UInt64 = min(10_000, options.maximumIndex)
    log("warming transform and allocation paths with F(\(warmupIndex))")
    _ = measure(index: warmupIndex, samples: 1, includeDigitCount: false)

    var probes: [Measurement] = []
    var low: UInt64 = min(1_000, options.maximumIndex)
    var lowMeasurement = recordProbe(index: low, samples: options.searchSamples, probes: &probes)

    while low > 1 && lowMeasurement.medianMilliseconds >= options.targetMilliseconds {
        low = max(1, low / 2)
        lowMeasurement = recordProbe(index: low, samples: options.searchSamples, probes: &probes)
    }

    var high = low
    var highMeasurement = lowMeasurement
    while highMeasurement.medianMilliseconds < options.targetMilliseconds && high < options.maximumIndex {
        low = high
        lowMeasurement = highMeasurement
        high = min(options.maximumIndex, high.multipliedReportingOverflow(by: 2).partialValue)
        guard high > low else { break }
        highMeasurement = recordProbe(index: high, samples: options.searchSamples, probes: &probes)
    }

    let searchResolution = max(1, high / 10_000)
    while high > low && high - low > searchResolution {
        let midpoint = low + (high - low) / 2
        let measurement = recordProbe(index: midpoint, samples: options.searchSamples, probes: &probes)
        if measurement.medianMilliseconds < options.targetMilliseconds {
            low = midpoint
            lowMeasurement = measurement
        } else {
            high = midpoint
            highMeasurement = measurement
        }
    }

    var acceptedIndex = low
    var accepted = measure(index: acceptedIndex, samples: options.finalSamples, includeDigitCount: true)

    while accepted.medianMilliseconds >= options.targetMilliseconds && acceptedIndex > searchResolution {
        acceptedIndex -= searchResolution
        accepted = measure(index: acceptedIndex, samples: options.finalSamples, includeDigitCount: true)
        log("validate F(\(acceptedIndex)): median \(format(accepted.medianMilliseconds)) ms")
    }

    var firstRejected: Measurement?
    for _ in 0..<64 {
        let (next, overflowed) = acceptedIndex.addingReportingOverflow(searchResolution)
        guard !overflowed, next <= options.maximumIndex else { break }
        let candidate = measure(index: next, samples: options.finalSamples, includeDigitCount: true)
        log("validate F(\(next)): median \(format(candidate.medianMilliseconds)) ms")
        if candidate.medianMilliseconds < options.targetMilliseconds {
            acceptedIndex = next
            accepted = candidate
        } else {
            firstRejected = candidate
            break
        }
    }

    let boundaryStatus: BoundaryStatus
    if firstRejected != nil {
        boundaryStatus = .observedRejection
    } else if acceptedIndex >= options.maximumIndex {
        boundaryStatus = .maximumIndexReached
    } else {
        boundaryStatus = .validationWindowExhausted
    }


    let representativeIndices = Set([
        roundedRepresentativeIndex(acceptedIndex, fraction: 0.25),
        roundedRepresentativeIndex(acceptedIndex, fraction: 0.50),
        roundedRepresentativeIndex(acceptedIndex, fraction: 0.75),
        acceptedIndex,
    ])

    var examples: [Measurement] = []
    for index in representativeIndices.sorted() {
        if index == acceptedIndex {
            examples.append(accepted)
        } else {
            log("example F(\(index))")
            examples.append(measure(index: index, samples: options.finalSamples, includeDigitCount: true))
        }
    }

    return BenchmarkReport(
        environment: environment(),
        protocolRecord: ProtocolRecord(
            targetMilliseconds: options.targetMilliseconds,
            searchSamplesPerCandidate: options.searchSamples,
            finalSamplesPerExample: options.finalSamples,
            maximumIndex: options.maximumIndex,
            searchResolution: searchResolution,
            backendPolicy: "Automatic (vDSP for transform-eligible work)",
            warmupIndex: warmupIndex,
            digitCountMethod: "floor(n × log10(φ) − log10(√5)) + 1 using 38-digit Decimal constants"
        ),
        boundary: Boundary(
            status: boundaryStatus,
            accepted: accepted,
            firstRejected: firstRejected
        ),
        examples: examples,
        searchProbes: probes
    )
}

private func printReport(_ report: BenchmarkReport) {
    let memoryGiB = Double(report.environment.physicalMemoryBytes) / 1_073_741_824
    print("# Headless Fibonacci benchmark")
    print()
    print("- Hardware: \(report.environment.hardware), \(String(format: "%.0f", memoryGiB)) GiB")
    print("- OS: \(report.environment.operatingSystem)")
    print("- Build: \(report.environment.buildConfiguration), arm64, \(report.protocolRecord.backendPolicy)")
    print("- Source: `\(report.environment.sourceRevision)\(report.environment.workingTreeDirty ? "-dirty" : "")`")
    print("- Protocol: median of \(report.protocolRecord.finalSamplesPerExample) steady-state samples; target < \(format(report.protocolRecord.targetMilliseconds)) ms")
    print()
    print("| Index | Decimal digits | Median | Minimum | Maximum |")
    print("|---:|---:|---:|---:|---:|")
    for measurement in report.examples {
        print("| \(measurement.index) | \(measurement.decimalDigits ?? 0) | \(format(measurement.medianMilliseconds)) ms | \(format(measurement.minimumMilliseconds)) ms | \(format(measurement.maximumMilliseconds)) ms |")
    }
    print()
    switch report.boundary.status {
    case .observedRejection:
        let rejected = report.boundary.firstRejected!
        print("Observed boundary: `F(\(report.boundary.accepted.index))` remained below the target median; `F(\(rejected.index))` did not.")
    case .maximumIndexReached:
        print("No rejection observed before the configured maximum index; `F(\(report.boundary.accepted.index))` remained below the target median.")
    case .validationWindowExhausted:
        print("No rejection observed in the 64-step validation window after `F(\(report.boundary.accepted.index))`; increase the search samples for a stable boundary.")
    }
    print("Result sink: \(resultSink)")
}

@main
private enum FibonacciBenchmark {
    static func main() {
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            let report = try run(options)
            printReport(report)

            if let outputPath = options.outputPath {
                let outputURL = URL(fileURLWithPath: outputPath)
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(report).write(to: outputURL, options: .atomic)
                print("Raw report: \(outputPath)")
            }
        } catch {
            FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
            printUsage()
            exit(EXIT_FAILURE)
        }
    }
}
