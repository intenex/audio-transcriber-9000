import Foundation

struct TranscriptionWord: Codable {
    let word: String
    let start: Double?
    let end: Double?
}

struct TranscriptionSegment: Codable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speaker: String
    let words: [TranscriptionWord]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(TimeInterval.self, forKey: .start)
        end = try c.decode(TimeInterval.self, forKey: .end)
        text = try c.decode(String.self, forKey: .text)
        speaker = try c.decode(String.self, forKey: .speaker)
        words = (try? c.decode([TranscriptionWord].self, forKey: .words)) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case start, end, text, speaker, words
    }
}

struct TranscriptionResult: Codable {
    let segments: [TranscriptionSegment]
    let language: String
    let numSpeakers: Int

    enum CodingKeys: String, CodingKey {
        case segments
        case language
        case numSpeakers = "num_speakers"
    }
}

// MARK: - Markdown Formatter

struct MarkdownFormatter {
    /// Maps raw speaker IDs like "SPEAKER_00" → "Speaker 1"
    static func speakerLabel(_ rawSpeaker: String, mapping: [String: Int]) -> String {
        if let n = mapping[rawSpeaker] {
            return "Speaker \(n)"
        }
        return rawSpeaker
    }

    static func format(result: TranscriptionResult, recording: Recording, customSpeakerNames: [String: String] = [:]) -> String {
        var lines: [String] = []

        // Header — use recording name if set
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        let dateStr = dateFormatter.string(from: recording.date)
        let title = recording.name ?? "Transcription — \(dateStr)"
        lines.append("# \(title)")
        lines.append("")
        lines.append("**Date:** \(dateStr)")
        lines.append("**Duration:** \(recording.durationString)")
        lines.append("**Speakers detected:** \(result.numSpeakers)")
        lines.append("")
        lines.append("---")
        lines.append("")

        // Build speaker mapping sorted by first appearance
        var speakerOrder: [String] = []
        var speakerMapping: [String: Int] = [:]
        for seg in result.segments {
            if speakerMapping[seg.speaker] == nil {
                speakerOrder.append(seg.speaker)
                speakerMapping[seg.speaker] = speakerOrder.count
            }
        }

        // Group consecutive segments by speaker
        var currentSpeaker: String? = nil
        var currentTexts: [String] = []

        func flushSpeaker(speaker: String, texts: [String], timestamp: TimeInterval) {
            let label = customSpeakerNames[speaker] ?? speakerLabel(speaker, mapping: speakerMapping)
            let ts = formatTimestamp(timestamp)
            lines.append("**\(label)** `[\(ts)]`")
            lines.append("")
            lines.append(texts.joined(separator: " "))
            lines.append("")
        }

        var firstTimestamp: TimeInterval = 0

        for seg in result.segments {
            if seg.speaker != currentSpeaker {
                if let prev = currentSpeaker, !currentTexts.isEmpty {
                    flushSpeaker(speaker: prev, texts: currentTexts, timestamp: firstTimestamp)
                }
                currentSpeaker = seg.speaker
                currentTexts = [seg.text]
                firstTimestamp = seg.start
            } else {
                currentTexts.append(seg.text)
            }
        }

        if let last = currentSpeaker, !currentTexts.isEmpty {
            flushSpeaker(speaker: last, texts: currentTexts, timestamp: firstTimestamp)
        }

        return lines.joined(separator: "\n")
    }

    /// Re-formats an existing markdown transcript by replacing speaker labels with custom names
    static func applyCustomNames(to markdown: String, segments: [TranscriptionSegment]?, customSpeakerNames: [String: String], recordingName: String?) -> String {
        guard !customSpeakerNames.isEmpty || recordingName != nil else { return markdown }

        var result = markdown

        // Replace the title if recording has a custom name
        if let name = recordingName {
            if let titleRange = result.range(of: #"^# .+$"#, options: .regularExpression) {
                result.replaceSubrange(titleRange, with: "# \(name)")
            }
        }

        // Build speaker number mapping from segments
        if let segments = segments {
            var speakerOrder: [String] = []
            var speakerMapping: [String: Int] = [:]
            for seg in segments {
                if speakerMapping[seg.speaker] == nil {
                    speakerOrder.append(seg.speaker)
                    speakerMapping[seg.speaker] = speakerOrder.count
                }
            }

            // Replace speaker labels
            for (rawID, customName) in customSpeakerNames {
                if let num = speakerMapping[rawID] {
                    let defaultLabel = "Speaker \(num)"
                    result = result.replacingOccurrences(of: "**\(defaultLabel)**", with: "**\(customName)**")
                }
            }
        }

        return result
    }

    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }
}
