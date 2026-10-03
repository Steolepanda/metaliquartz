import Foundation
import Observation

struct RenderDiagnosticsSnapshot: Hashable, Sendable {
    var framesPerSecond: Double = 0
    var cpuFrameMilliseconds: Double = 0
    var gpuFrameMilliseconds: Double = 0
    var p95FrameMilliseconds: Double = 0
    var droppedFrames: UInt64 = 0
    var totalFrames: UInt64 = 0
    var texturePool = TexturePoolStats(totalAllocated: 0, available: 0)
    var nodeErrors: [NodeID: String] = [:]

    var droppedFramePercentage: Double {
        guard totalFrames > 0 else { return 0 }
        return Double(droppedFrames) / Double(totalFrames) * 100
    }
}

@MainActor
@Observable
final class RenderDiagnosticsModel {
    private(set) var snapshot = RenderDiagnosticsSnapshot()
    private var recentFrameMilliseconds: [Double] = []
    private let sampleCapacity = 600

    func record(
        frameInterval: Double,
        cpuMilliseconds: Double,
        gpuMilliseconds: Double,
        dropped: Bool,
        texturePool: TexturePoolStats,
        nodeErrors: [NodeID: String]
    ) {
        snapshot.totalFrames &+= 1
        if dropped { snapshot.droppedFrames &+= 1 }
        let instantaneousFPS = frameInterval > 0 ? 1 / frameInterval : 0
        snapshot.framesPerSecond = smooth(snapshot.framesPerSecond, instantaneousFPS)
        snapshot.cpuFrameMilliseconds = smooth(
            snapshot.cpuFrameMilliseconds,
            cpuMilliseconds
        )
        snapshot.gpuFrameMilliseconds = smooth(
            snapshot.gpuFrameMilliseconds,
            gpuMilliseconds
        )
        recentFrameMilliseconds.append(max(cpuMilliseconds, gpuMilliseconds))
        if recentFrameMilliseconds.count > sampleCapacity {
            recentFrameMilliseconds.removeFirst(
                recentFrameMilliseconds.count - sampleCapacity
            )
        }
        snapshot.p95FrameMilliseconds = percentile95(recentFrameMilliseconds)
        snapshot.texturePool = texturePool
        snapshot.nodeErrors = nodeErrors
    }

    func reset() {
        snapshot = RenderDiagnosticsSnapshot()
        recentFrameMilliseconds.removeAll(keepingCapacity: true)
    }

    private func smooth(_ previous: Double, _ next: Double) -> Double {
        previous == 0 ? next : previous * 0.9 + next * 0.1
    }

    private func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let ordered = values.sorted()
        let index = min(ordered.count - 1, Int(ceil(Double(ordered.count) * 0.95)) - 1)
        return ordered[index]
    }
}
