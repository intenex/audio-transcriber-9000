import Accelerate
import Foundation

/// Cosine-similarity matching of a speaker embedding against the enrolled library.
enum SpeakerMatcher {
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }

    /// Best match = highest max-similarity across each speaker's stored embeddings,
    /// if it clears the threshold.
    static func match(embedding: [Float], against speakers: [EnrolledSpeaker],
                      threshold: Float) -> (speaker: EnrolledSpeaker, score: Float)? {
        var best: (speaker: EnrolledSpeaker, score: Float)? = nil
        for speaker in speakers {
            let score = speaker.embeddings.map { cosineSimilarity(embedding, $0) }.max() ?? 0
            if score >= threshold, score > (best?.score ?? -1) {
                best = (speaker, score)
            }
        }
        return best
    }
}
