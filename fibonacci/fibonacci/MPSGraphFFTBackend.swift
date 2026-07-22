//
//  MPSGraphFFTBackend.swift
//  fibonacci
//
//  Float32 GPU convolution for large integer workloads.
//

import Foundation
import Metal
import MetalPerformanceShadersGraph
import os

enum MPSGraphFFTBackend {
    nonisolated private enum Operation: Hashable, Sendable {
        case multiply
        case square
    }

    nonisolated private struct PlanKey: Hashable, Sendable {
        let size: Int
        let operation: Operation
    }

    nonisolated private final class Context: @unchecked Sendable {
        let device: MTLDevice?
        let queue: MTLCommandQueue?
        let graphDevice: MPSGraphDevice?

        nonisolated init() {
            #if targetEnvironment(simulator)
            // The simulator exposes a Metal device but not a usable MPSGraph device.
            self.device = nil
            self.queue = nil
            self.graphDevice = nil
            #else
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.queue = device?.makeCommandQueue()
            self.graphDevice = device.map(MPSGraphDevice.init(mtlDevice:))
            #endif
        }
    }

    nonisolated private final class Plan: @unchecked Sendable {
        let graph: MPSGraph
        let firstInput: MPSGraphTensor
        let secondInput: MPSGraphTensor?
        let output: MPSGraphTensor
        let size: Int

        nonisolated init(size: Int, operation: Operation) {
            self.size = size

            let graph = MPSGraph()
            let shape = [NSNumber(value: size)]
            let firstInput = graph.placeholder(shape: shape, dataType: .float32, name: "lhs")

            let forward = MPSGraphFFTDescriptor()
            forward.inverse = false
            forward.scalingMode = .none
            let firstSpectrum = graph.realToHermiteanFFT(
                firstInput,
                axes: [0],
                descriptor: forward,
                name: "lhs.fft"
            )

            let secondInput: MPSGraphTensor?
            let product: MPSGraphTensor
            switch operation {
            case .multiply:
                let input = graph.placeholder(shape: shape, dataType: .float32, name: "rhs")
                let spectrum = graph.realToHermiteanFFT(
                    input,
                    axes: [0],
                    descriptor: forward,
                    name: "rhs.fft"
                )
                secondInput = input
                product = graph.multiplication(firstSpectrum, spectrum, name: "spectrum.product")
            case .square:
                secondInput = nil
                product = graph.multiplication(firstSpectrum, firstSpectrum, name: "spectrum.square")
            }

            let inverse = MPSGraphFFTDescriptor()
            inverse.inverse = true
            inverse.scalingMode = .size

            self.graph = graph
            self.firstInput = firstInput
            self.secondInput = secondInput
            self.output = graph.HermiteanToRealFFT(
                product,
                axes: [0],
                descriptor: inverse,
                name: "convolution"
            )
        }
    }

    nonisolated private struct Cache: Sendable {
        var plans: [PlanKey: Plan] = [:]
    }

    nonisolated private static let context = Context()
    nonisolated private static let cacheLock = OSAllocatedUnfairLock(initialState: Cache())
    nonisolated private static let maximumCachedPlans = 6

    nonisolated static var isAvailable: Bool {
        context.device != nil && context.queue != nil && context.graphDevice != nil
    }

    nonisolated static var deviceName: String? {
        context.device?.name
    }

    nonisolated static func multiply(_ lhs: [Float], _ rhs: [Float], fftSize: Int) -> [Float]? {
        execute(lhs, rhs, fftSize: fftSize, operation: .multiply)
    }

    nonisolated static func square(_ input: [Float], fftSize: Int) -> [Float]? {
        execute(input, nil, fftSize: fftSize, operation: .square)
    }

    nonisolated private static func execute(
        _ first: [Float],
        _ second: [Float]?,
        fftSize: Int,
        operation: Operation
    ) -> [Float]? {
        guard isAvailable,
              fftSize >= 4,
              fftSize.nonzeroBitCount == 1,
              first.count <= fftSize,
              second?.count ?? 0 <= fftSize,
              let queue = context.queue,
              let graphDevice = context.graphDevice else {
            return nil
        }

        return cacheLock.withLock { cache in
            let key = PlanKey(size: fftSize, operation: operation)
            let plan: Plan
            if let cached = cache.plans[key] {
                plan = cached
            } else {
                if cache.plans.count >= maximumCachedPlans,
                   let evictionKey = cache.plans.keys.first {
                    cache.plans.removeValue(forKey: evictionKey)
                }
                let created = Plan(size: fftSize, operation: operation)
                cache.plans[key] = created
                plan = created
            }

            return autoreleasepool {
                var firstPadded = [Float](repeating: 0, count: fftSize)
                firstPadded.replaceSubrange(0..<first.count, with: first)

                let firstData = tensorData(firstPadded, device: graphDevice)
                var feeds: [MPSGraphTensor: MPSGraphTensorData] = [plan.firstInput: firstData]

                if let second,
                   let secondInput = plan.secondInput {
                    var secondPadded = [Float](repeating: 0, count: fftSize)
                    secondPadded.replaceSubrange(0..<second.count, with: second)
                    feeds[secondInput] = tensorData(secondPadded, device: graphDevice)
                }

                guard let result = plan.graph.run(
                    with: queue,
                    feeds: feeds,
                    targetTensors: [plan.output],
                    targetOperations: nil
                )[plan.output] else {
                    return nil
                }

                var values = [Float](repeating: 0, count: fftSize)
                result.mpsndarray().readBytes(&values, strideBytes: nil)
                return values
            }
        }
    }

    nonisolated private static func tensorData(
        _ values: [Float],
        device: MPSGraphDevice
    ) -> MPSGraphTensorData {
        let data = values.withUnsafeBytes { Data($0) }
        return MPSGraphTensorData(
            device: device,
            data: data,
            shape: [NSNumber(value: values.count)],
            dataType: .float32
        )
    }
}
