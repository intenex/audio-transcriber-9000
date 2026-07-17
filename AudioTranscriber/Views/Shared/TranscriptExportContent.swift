import Foundation

/// Renders lightweight inline markdown for display (bold/italic preserved,
/// whitespace kept). Shared by the transcript and summary tabs.
func attributedMarkdown(_ markdown: String) -> AttributedString {
    (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
}

/// Pure builders for exportable markdown documents — shared by the Mac
/// NSSavePanel flows and the iOS ShareLink flows.
enum TranscriptExportContent {
    static func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalidChars).joined(separator: "_")
    }

    static func summaryMarkdown(_ summary: RecordingSummary, recording: Recording) -> String {
        var lines: [String] = []
        let title = recording.name ?? "Recording — \(recording.formattedDate)"
        lines.append("# Summary: \(title)")
        lines.append("")
        if let topics = summary.topics, !topics.isEmpty {
            lines.append("**Topics:** \(topics.joined(separator: ", "))")
            lines.append("")
        }
        lines.append("## Summary")
        lines.append("")
        lines.append(summary.summary)
        lines.append("")
        if let keyPoints = summary.keyPoints, !keyPoints.isEmpty {
            lines.append("## Key Points")
            lines.append("")
            for point in keyPoints { lines.append("- \(point)") }
            lines.append("")
        }
        if let decisions = summary.decisions, !decisions.isEmpty {
            lines.append("## Decisions")
            lines.append("")
            for decision in decisions { lines.append("- \(decision)") }
            lines.append("")
        }
        if !summary.actionItems.isEmpty {
            lines.append("## Action Items")
            lines.append("")
            for item in summary.actionItems {
                lines.append("- [ ] \(item)")
            }
            lines.append("")
        }
        lines.append("---")
        lines.append("*Generated \(summary.generatedAt.formatted())\(summary.modelUsed.map { " with \($0)" } ?? "")*")
        return lines.joined(separator: "\n")
    }

    /// nil when the recording has no chat history sidecar.
    static func chatMarkdown(for recording: Recording) -> String? {
        guard let data = try? Data(contentsOf: recording.chatURL),
              let history = try? JSONDecoder().decode(ChatHistory.self, from: data) else { return nil }

        var lines: [String] = []
        let title = recording.name ?? "Recording — \(recording.formattedDate)"
        lines.append("# Chat: \(title)")
        lines.append("")

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        for msg in history.messages where msg.role != .system {
            let sender = msg.role == .user ? "**You**" : "**AI**"
            lines.append("\(sender) — \(dateFormatter.string(from: msg.timestamp))")
            lines.append("")
            lines.append(msg.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
