import Foundation
import FluidAudio

/// Assembles word-level timings from FluidAudio's SentencePiece token timings.
/// FluidAudio normalizes tokens by replacing the SentencePiece "▁" word marker
/// with a space, so a new word starts when a token begins with a space (or a
/// raw "▁" from unnormalized sources); other tokens extend the current word.
enum WordTimingAssembler {
    static func words(from timings: [TokenTiming]) -> [(word: String, start: Double, end: Double)] {
        assemble(tokens: timings.map { ($0.token, $0.startTime, $0.endTime) })
    }

    /// Pure core (testable without FluidAudio types).
    static func assemble(tokens: [(token: String, start: Double, end: Double)])
        -> [(word: String, start: Double, end: Double)] {
        var result: [(word: String, start: Double, end: Double)] = []
        var currentText = ""
        var currentStart: Double = 0
        var currentEnd: Double = 0

        func flush() {
            let trimmed = currentText.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                result.append((trimmed, currentStart, max(currentEnd, currentStart)))
            }
            currentText = ""
        }

        for timing in tokens {
            let raw = timing.token
            let startsWord = raw.hasPrefix("▁") || raw.hasPrefix(" ")
            let text = raw.replacingOccurrences(of: "▁", with: " ")

            if startsWord || currentText.isEmpty {
                flush()
                currentText = text
                currentStart = timing.start
                currentEnd = timing.end
            } else {
                currentText += text
                currentEnd = timing.end
            }
        }
        flush()
        return result
    }
}
