import Foundation
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

/// A rendered word's character range and its absolute time span — the core of
/// click-to-seek and playback highlighting.
struct TranscriptWordRange: Equatable {
    let range: NSRange
    let start: TimeInterval
    let end: TimeInterval
}

/// Platform-neutral transcript rendering: groups consecutive same-speaker
/// segments, emits "Name   [h:mm:ss]" headers + word runs, and records the
/// per-word NSRange→time map. The Mac NSTextView and iOS UITextView wrappers
/// both consume this so their text, ranges, and highlight geometry match.
enum TranscriptTextBuilder {
    struct Output {
        let text: NSMutableAttributedString
        let wordRanges: [TranscriptWordRange]
    }

    static func build(segments: [TranscriptionSegment],
                      speakerNames: [String: String]) -> Output {
        var wordRanges: [TranscriptWordRange] = []
        let result = NSMutableAttributedString()

        // Speaker mapping: first appearance = Speaker 1, etc.
        var speakerOrder: [String] = []
        var speakerMapping: [String: Int] = [:]
        for seg in segments {
            if speakerMapping[seg.speaker] == nil {
                speakerOrder.append(seg.speaker)
                speakerMapping[seg.speaker] = speakerOrder.count
            }
        }

        let bodyFont = PlatformFont.systemFont(ofSize: 14)
        let headerFont = PlatformFont.boldSystemFont(ofSize: 13)
        #if os(macOS)
        let headerColor = PlatformColor.secondaryLabelColor
        let bodyColor = PlatformColor.labelColor
        #else
        let headerColor = PlatformColor.secondaryLabel
        let bodyColor = PlatformColor.label
        #endif

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 5

        let headerParagraph = NSMutableParagraphStyle()
        headerParagraph.paragraphSpacingBefore = 20

        // Group consecutive same-speaker segments
        struct Group {
            let speaker: String
            let firstTime: TimeInterval
            var words: [(text: String, start: TimeInterval, end: TimeInterval)]
        }
        var groups: [Group] = []

        for seg in segments {
            let segWords: [(text: String, start: TimeInterval, end: TimeInterval)]
            if !seg.words.isEmpty {
                segWords = seg.words.compactMap { w -> (String, TimeInterval, TimeInterval)? in
                    let text = w.word.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return nil }
                    return (text, w.start ?? seg.start, w.end ?? seg.end)
                }
            } else {
                let parts = seg.text.components(separatedBy: " ").filter { !$0.isEmpty }
                let count = max(1, parts.count)
                let wordDuration = (seg.end - seg.start) / Double(count)
                segWords = parts.enumerated().map { (i, word) in
                    (word, seg.start + Double(i) * wordDuration, seg.start + Double(i + 1) * wordDuration)
                }
            }

            if let lastIdx = groups.indices.last, groups[lastIdx].speaker == seg.speaker {
                groups[groups.count - 1].words.append(contentsOf: segWords)
            } else {
                groups.append(Group(speaker: seg.speaker, firstTime: seg.start, words: segWords))
            }
        }

        // Render each speaker group
        for (gi, group) in groups.enumerated() {
            let speakerNum = speakerMapping[group.speaker] ?? 1
            let customName = speakerNames[group.speaker]
            let displayName = customName ?? "Speaker \(speakerNum)"
            let ts = formatTimestamp(group.firstTime)
            let headerPara = gi == 0 ? NSMutableParagraphStyle() : headerParagraph

            let headerStr = "\(displayName)   [\(ts)]\n"
            result.append(NSAttributedString(string: headerStr, attributes: [
                .font: headerFont,
                .foregroundColor: headerColor,
                .paragraphStyle: headerPara
            ]))

            for word in group.words {
                guard !word.text.isEmpty else { continue }
                let rangeStart = result.length
                result.append(NSAttributedString(string: word.text, attributes: [
                    .font: bodyFont,
                    .foregroundColor: bodyColor,
                    .paragraphStyle: bodyParagraph
                ]))
                wordRanges.append(TranscriptWordRange(
                    range: NSRange(location: rangeStart, length: (word.text as NSString).length),
                    start: word.start,
                    end: word.end
                ))
                result.append(NSAttributedString(string: " ", attributes: [
                    .font: bodyFont,
                    .paragraphStyle: bodyParagraph
                ]))
            }

            result.append(NSAttributedString(string: "\n\n"))
        }

        return Output(text: result, wordRanges: wordRanges)
    }

    /// Case-insensitive match ranges for search highlighting.
    static func searchRanges(in fullText: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var ranges: [NSRange] = []
        let lowered = fullText.lowercased()
        let loweredQuery = query.lowercased()
        var searchStart = lowered.startIndex
        while let range = lowered.range(of: loweredQuery, range: searchStart..<lowered.endIndex) {
            ranges.append(NSRange(range, in: fullText))
            searchStart = range.upperBound
        }
        return ranges
    }

    /// The word whose [start, end) span contains `time`.
    static func wordRange(at time: Double, in ranges: [TranscriptWordRange]) -> NSRange? {
        for entry in ranges where time >= entry.start && time < entry.end {
            return entry.range
        }
        return nil
    }

    /// The word (if any) containing a tapped/clicked character index.
    static func seekTime(forCharacterAt index: Int, in ranges: [TranscriptWordRange]) -> TimeInterval? {
        for entry in ranges where NSLocationInRange(index, entry.range) {
            return entry.start
        }
        return nil
    }

    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }
}
