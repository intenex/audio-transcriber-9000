import Foundation
import FluidAudio

/// Assembles word-level timings from FluidAudio's SentencePiece token timings.
/// A token starting with "▁" begins a new word; other tokens extend the current one.
enum WordTimingAssembler {
    static func words(from timings: [TokenTiming]) -> [(word: String, start: Double, end: Double)] {
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

        for timing in timings {
            let raw = timing.token
            let startsWord = raw.hasPrefix("▁")
            let text = raw.replacingOccurrences(of: "▁", with: "")

            if startsWord || currentText.isEmpty {
                flush()
                currentText = text
                currentStart = timing.startTime
                currentEnd = timing.endTime
            } else {
                currentText += text
                currentEnd = timing.endTime
            }
        }
        flush()
        return result
    }
}
