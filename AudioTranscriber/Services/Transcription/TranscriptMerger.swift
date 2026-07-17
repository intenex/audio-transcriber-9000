import Foundation

/// Merges a labeled word stream into TranscriptionSegments, splitting on
/// speaker change, long inter-word gaps, sentence-final punctuation, and a
/// maximum segment length.
enum TranscriptMerger {
    static let maxSegmentSeconds: Double = 30
    static let hardGapSeconds: Double = 0.8
    static let sentenceGapSeconds: Double = 0.3

    static func makeSegments(from words: [LabeledWord]) -> [TranscriptionSegment] {
        guard !words.isEmpty else { return [] }

        var segments: [TranscriptionSegment] = []
        var current: [LabeledWord] = [words[0]]

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(TranscriptionSegment(
                start: first.start,
                end: last.end,
                text: current.map(\.word).joined(separator: " "),
                speaker: first.speaker,
                words: current.map { TranscriptionWord(word: $0.word, start: $0.start, end: $0.end) }
            ))
            current = []
        }

        for (prev, word) in zip(words, words.dropFirst()) {
            let gap = word.start - prev.end
            let speakerChanged = word.speaker != prev.speaker
            let sentenceEnded = prev.word.hasSuffix(".") || prev.word.hasSuffix("?") || prev.word.hasSuffix("!")
            let tooLong = (word.end - (current.first?.start ?? word.start)) > maxSegmentSeconds

            if speakerChanged
                || gap > hardGapSeconds
                || (sentenceEnded && gap > sentenceGapSeconds)
                || tooLong {
                flush()
            }
            current.append(word)
        }
        flush()
        return segments
    }

    /// Interpolate evenly-spaced word timings for chunk text when the ASR
    /// backend provides no token timings (same approach as the transcript UI's
    /// fallback path).
    static func interpolateWords(text: String, start: Double, end: Double) -> [(word: String, start: Double, end: Double)] {
        let parts = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return [] }
        let step = max(0, end - start) / Double(parts.count)
        return parts.enumerated().map { i, w in
            (w, start + Double(i) * step, start + Double(i + 1) * step)
        }
    }
}
