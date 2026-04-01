import Foundation
import Metal
import CoreML

/// Runtime Apple Silicon hardware profile — all decisions based on capability queries, never chip names.
final class SiliconProfile {
    static let shared = SiliconProfile()

    enum ComputeTier: Int, Comparable, CustomStringConvertible {
        case base = 0      // M1 base, 8GB
        case mid = 1       // M1 Pro, M2, 16GB
        case high = 2      // M3 Pro/Max, 32GB+
        case ultra = 3     // Any Ultra, 64GB+

        static func < (lhs: ComputeTier, rhs: ComputeTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var description: String {
            switch self {
            case .base: return "Base"
            case .mid: return "Mid"
            case .high: return "High"
            case .ultra: return "Ultra"
            }
        }
    }

    let performanceCoreCount: Int
    let efficiencyCoreCount: Int
    let totalCoreCount: Int
    let totalMemoryGB: Int
    let hasNeuralEngine: Bool
    let hasMetalSupport: Bool
    let metalGPUFamily: Int  // 0 if no Metal
    let computeTier: ComputeTier
    let chipName: String  // for LOGGING ONLY, never for branching

    private init() {
        // P-cores
        performanceCoreCount = Self.sysctlInt("hw.perflevel0.physicalcpu") ?? (ProcessInfo.processInfo.activeProcessorCount / 2)
        // E-cores
        efficiencyCoreCount = Self.sysctlInt("hw.perflevel1.physicalcpu") ?? (ProcessInfo.processInfo.activeProcessorCount - performanceCoreCount)
        totalCoreCount = ProcessInfo.processInfo.activeProcessorCount
        totalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        chipName = Self.sysctlString("machdep.cpu.brand_string") ?? "Unknown"

        // Neural Engine — check CoreML compute devices
        if #available(macOS 14.0, *) {
            hasNeuralEngine = MLComputeDevice.allComputeDevices.contains { device in
                if case .neuralEngine = device { return true }
                return false
            }
        } else {
            // Pre-14.0: assume Apple Silicon has NE
            hasNeuralEngine = true
        }

        // Metal GPU
        if let device = MTLCreateSystemDefaultDevice() {
            hasMetalSupport = true
            // Detect highest supported GPU family
            if device.supportsFamily(.apple9) { metalGPUFamily = 9 }
            else if device.supportsFamily(.apple8) { metalGPUFamily = 8 }
            else if device.supportsFamily(.apple7) { metalGPUFamily = 7 }
            else if device.supportsFamily(.apple6) { metalGPUFamily = 6 }
            else if device.supportsFamily(.apple5) { metalGPUFamily = 5 }
            else { metalGPUFamily = 4 }
        } else {
            hasMetalSupport = false
            metalGPUFamily = 0
        }

        // Derive compute tier from capabilities (NOT chip name)
        if totalMemoryGB >= 64 || performanceCoreCount >= 16 {
            computeTier = .ultra
        } else if totalMemoryGB >= 32 || performanceCoreCount >= 10 {
            computeTier = .high
        } else if totalMemoryGB >= 16 || performanceCoreCount >= 6 {
            computeTier = .mid
        } else {
            computeTier = .base
        }

        print("[SiliconProfile] \(chipName): \(performanceCoreCount)P+\(efficiencyCoreCount)E cores, \(totalMemoryGB)GB, Metal family \(metalGPUFamily), NE=\(hasNeuralEngine), tier=\(computeTier)")
    }

    // MARK: - Recommendations

    var recommendedOllamaModel: String {
        switch computeTier {
        case .base:  return "qwen2.5:1.5b"
        case .mid:   return "qwen2.5:3b"
        case .high:  return "qwen2.5:7b"
        case .ultra: return "qwen2.5:14b"
        }
    }

    var recommendedMaxConcurrentAgents: Int {
        switch computeTier {
        case .base:  return 1
        case .mid:   return 2
        case .high:  return 3
        case .ultra: return 4
        }
    }

    var canRunLocalEmbeddings: Bool {
        totalMemoryGB >= 16 && hasNeuralEngine
    }

    var learnAllBatchSize: Int {
        switch computeTier {
        case .base:  return 10
        case .mid:   return 25
        case .high:  return 50
        case .ultra: return 100
        }
    }

    var learnAllCooldownMs: Int {
        switch computeTier {
        case .base:  return 500
        case .mid:   return 200
        case .high:  return 100
        case .ultra: return 50
        }
    }

    // MARK: - sysctl Helpers

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
