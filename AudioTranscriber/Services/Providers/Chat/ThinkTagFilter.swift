import Foundation

/// Splits streamed model output into visible content vs `<think>…</think>`
/// reasoning. MiniMax-M3 (and other reasoning models) embed the think block
/// INSIDE `content` deltas, which would otherwise leak into chat bubbles and
/// break JSON parsing of structured outputs. Tags may arrive split across
/// chunk boundaries, so the filter is stateful.
struct ThinkTagFilter {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var insideThink = false
    private var carry = ""

    /// Process one streamed chunk; returns what should be shown vs treated as reasoning.
    mutating func process(_ text: String) -> (content: String, reasoning: String) {
        var buffer = carry + text
        carry = ""
        var content = ""
        var reasoning = ""

        while !buffer.isEmpty {
            let tag = insideThink ? Self.closeTag : Self.openTag
            if let range = buffer.range(of: tag) {
                let before = String(buffer[..<range.lowerBound])
                if insideThink { reasoning += before } else { content += before }
                insideThink.toggle()
                buffer = String(buffer[range.upperBound...])
            } else {
                // No complete tag: hold back the longest suffix that could be
                // the start of the next tag; emit the rest.
                let keep = Self.partialTagSuffixLength(of: buffer, tag: tag)
                let emitEnd = buffer.index(buffer.endIndex, offsetBy: -keep)
                let emit = String(buffer[..<emitEnd])
                if insideThink { reasoning += emit } else { content += emit }
                carry = String(buffer[emitEnd...])
                buffer = ""
            }
        }
        return (content, reasoning)
    }

    /// Emit anything still held back once the stream ends.
    mutating func flush() -> (content: String, reasoning: String) {
        defer { carry = ""; insideThink = false }
        return insideThink ? ("", carry) : (carry, "")
    }

    private static func partialTagSuffixLength(of buffer: String, tag: String) -> Int {
        let maxLen = min(buffer.count, tag.count - 1)
        guard maxLen > 0 else { return 0 }
        for length in stride(from: maxLen, through: 1, by: -1) {
            let suffix = buffer.suffix(length)
            if tag.hasPrefix(suffix) { return length }
        }
        return 0
    }
}

extension String {
    /// One-shot removal of complete `<think>…</think>` blocks (non-streaming paths).
    func strippingThinkBlocks() -> String {
        var filter = ThinkTagFilter()
        let processed = filter.process(self)
        let flushed = filter.flush()
        return (processed.content + flushed.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
