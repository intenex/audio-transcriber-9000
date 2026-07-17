import Foundation

struct ChunkSpec: Codable, Sendable, Equatable {
    let index: Int
    let startSeconds: Double
    let endSeconds: Double

    var duration: Double { endSeconds - startSeconds }
}

/// Plans resumable ASR chunks: ~target-length windows whose boundaries snap to
/// the midpoint of the nearest silence gap (from VAD speech segments) so chunk
/// seams avoid cutting words. Pure logic — VAD output is passed in as data.
enum ChunkPlanner {
    static func plan(durationSeconds: Double,
                     speechSegments: [ClosedRange<Double>],
                     targetChunkSeconds: Double = 180,
                     snapWindowSeconds: Double = 30) -> [ChunkSpec] {
        guard durationSeconds > 0 else { return [] }
        guard durationSeconds > targetChunkSeconds * 1.25 else {
            return [ChunkSpec(index: 0, startSeconds: 0, endSeconds: durationSeconds)]
        }

        // Midpoints of silence gaps between consecutive speech segments.
        let sorted = speechSegments.sorted { $0.lowerBound < $1.lowerBound }
        var gapMidpoints: [Double] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.lowerBound > a.upperBound {
            gapMidpoints.append((a.upperBound + b.lowerBound) / 2)
        }

        var boundaries: [Double] = [0]
        var cursor: Double = 0
        while durationSeconds - cursor > targetChunkSeconds * 1.25 {
            let target = cursor + targetChunkSeconds
            let snapped = gapMidpoints
                .filter { abs($0 - target) <= snapWindowSeconds && $0 > cursor + 1 }
                .min { abs($0 - target) < abs($1 - target) }
            let boundary = min(snapped ?? target, durationSeconds - 1)
            boundaries.append(boundary)
            cursor = boundary
        }
        boundaries.append(durationSeconds)

        return zip(boundaries, boundaries.dropFirst()).enumerated().map { idx, pair in
            ChunkSpec(index: idx, startSeconds: pair.0, endSeconds: pair.1)
        }
    }
}
