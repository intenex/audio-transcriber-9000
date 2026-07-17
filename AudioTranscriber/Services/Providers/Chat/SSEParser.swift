import Foundation

/// Incremental Server-Sent-Events parser. Feed raw byte chunks as they arrive;
/// it emits the payload of each complete `data:` event, handling events split
/// across chunk boundaries, CRLF/LF line endings, multi-line data fields,
/// comment lines, and non-data fields (event:/id:/retry:).
struct SSEParser {
    private var buffer = ""
    private var pendingDataLines: [String] = []

    /// Consume a chunk of bytes; returns any completed event payloads.
    mutating func consume(_ chunk: Data) -> [String] {
        guard let text = String(data: chunk, encoding: .utf8) else { return [] }
        return consume(text)
    }

    mutating func consume(_ text: String) -> [String] {
        buffer += text
        var events: [String] = []

        // Process complete lines; keep the trailing partial line in the buffer.
        // Note: "\r\n" is a single Character in Swift, so match it explicitly.
        while let newlineIndex = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            var line = String(buffer[buffer.startIndex..<newlineIndex])
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if line.hasSuffix("\r") { line.removeLast() }

            if line.isEmpty {
                // Blank line = event boundary
                if !pendingDataLines.isEmpty {
                    events.append(pendingDataLines.joined(separator: "\n"))
                    pendingDataLines = []
                }
            } else if line.hasPrefix(":") {
                continue // comment
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                pendingDataLines.append(value)
            }
            // event:/id:/retry: fields ignored
        }
        return events
    }

    /// Flush any trailing event not terminated by a blank line (stream ended).
    mutating func finish() -> [String] {
        var events: [String] = []
        if buffer.hasPrefix("data:") {
            var value = String(buffer.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            if value.hasSuffix("\r") { value.removeLast() }
            pendingDataLines.append(value)
        }
        buffer = ""
        if !pendingDataLines.isEmpty {
            events.append(pendingDataLines.joined(separator: "\n"))
            pendingDataLines = []
        }
        return events
    }
}
