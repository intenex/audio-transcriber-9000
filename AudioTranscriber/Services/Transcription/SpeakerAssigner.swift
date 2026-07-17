import Foundation

/// A diarization turn: a time span attributed to one speaker.
struct SpeakerTurn: Sendable, Equatable {
    let start: Double
    let end: Double
    let speaker: String
}

/// Timed word with an assigned speaker.
struct LabeledWord: Sendable, Equatable {
    let word: String
    let start: Double
    let end: Double
    var speaker: String
}

/// Swift port of whisperX's assign_word_speakers: each word gets the speaker
/// turn with maximum temporal overlap; ties go to the earlier turn; words with
/// no overlap get the turn whose midpoint is nearest (fill-nearest, so no word
/// is left unlabeled). O(n + m) two-pointer over sorted inputs.
enum SpeakerAssigner {
    static func assign(words: [(word: String, start: Double, end: Double)],
                       turns: [SpeakerTurn],
                       fallbackSpeaker: String = "SPEAKER_00") -> [LabeledWord] {
        guard !turns.isEmpty else {
            return words.map { LabeledWord(word: $0.word, start: $0.start, end: $0.end, speaker: fallbackSpeaker) }
        }
        let sortedTurns = turns.sorted { $0.start < $1.start }
        var result: [LabeledWord] = []
        result.reserveCapacity(words.count)

        var lower = 0
        for w in words {
            // Advance the lower bound past turns that end before this word starts
            // (keep one behind for nearest-fallback).
            while lower < sortedTurns.count - 1 && sortedTurns[lower].end < w.start
                    && sortedTurns[lower + 1].start <= w.start {
                lower += 1
            }

            var best: (speaker: String, overlap: Double)? = nil
            var idx = lower
            while idx < sortedTurns.count && sortedTurns[idx].start < w.end {
                let t = sortedTurns[idx]
                let overlap = max(0, min(w.end, t.end) - max(w.start, t.start))
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (t.speaker, overlap)  // strict > keeps earlier turn on ties
                }
                idx += 1
            }

            let speaker: String
            if let best {
                speaker = best.speaker
            } else {
                // No overlap — nearest turn by midpoint distance.
                let mid = (w.start + w.end) / 2
                let nearest = sortedTurns.min {
                    abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid)
                }
                speaker = nearest?.speaker ?? fallbackSpeaker
            }
            result.append(LabeledWord(word: w.word, start: w.start, end: w.end, speaker: speaker))
        }
        return result
    }

    /// Relabel speakers to SPEAKER_00, SPEAKER_01… in first-appearance order.
    static func normalizeSpeakerIDs(_ words: [LabeledWord]) -> (words: [LabeledWord], mapping: [String: String]) {
        var mapping: [String: String] = [:]
        var next = 0
        var out: [LabeledWord] = []
        out.reserveCapacity(words.count)
        for var w in words {
            if let mapped = mapping[w.speaker] {
                w.speaker = mapped
            } else {
                let label = String(format: "SPEAKER_%02d", next)
                mapping[w.speaker] = label
                w.speaker = label
                next += 1
            }
            out.append(w)
        }
        return (out, mapping)
    }
}
