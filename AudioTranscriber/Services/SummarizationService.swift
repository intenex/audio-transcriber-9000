import Foundation

struct SummarizationService {

    /// Summarize a transcript. `namingContext` (optional) carries identified
    /// speakers and the names of past calls with those speakers so generated
    /// names follow an established series pattern (e.g. ongoing therapy calls).
    static func summarize(transcript: String, provider: any ChatProvider,
                          namingContext: String? = nil) async throws -> RecordingSummary {
        // Leave room for the instructions inside the provider's context budget.
        let budget = max(2_000, provider.contextCharacterBudget - 1_500)

        var contextBlock = ""
        if let namingContext, !namingContext.isEmpty {
            contextBlock = """

            Context about this recording:
            \(namingContext)

            """
        }

        let prompt = """
        Analyze this conversation transcript and respond with a JSON object with exactly these fields:
        - "summary": 2-4 crisp paragraphs covering what the conversation was about, what was discussed, and how it concluded. Refer to speakers by name when names are known. You may use **bold** for emphasis on names and key terms.
        - "keyPoints": array of 3-8 short bullet strings — the most important facts, findings, or moments.
        - "decisions": array of strings — decisions that were made or agreed on (empty array if none).
        - "actionItems": array of strings — concrete follow-ups/tasks. Format each as "task — owner" when the responsible person is identifiable, otherwise just the task.
        - "topics": array of 2-5 short lowercase tags describing the subject matter (e.g. "fertility", "scheduling", "budget").
        - "generatedName": a short, specific, descriptive title (max 6 words). If the context above shows this call belongs to a series of similarly named past calls, follow the SAME naming pattern as those calls.
        \(contextBlock)
        Respond ONLY with valid JSON — no markdown code fences, no commentary.

        Transcript:
        \(transcript.prefix(budget))
        """

        let system = "You are an expert conversation analyst. Always respond with a single valid JSON object and nothing else."

        let response = try await provider.generate(prompt: prompt, system: system)
        var summary = try parseSummaryJSON(response)
        summary.modelUsed = provider.modelIdentity
        return summary
    }

    static func loadSummary(for recording: Recording) -> RecordingSummary? {
        let url = summaryURL(for: recording)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingSummary.self, from: data)
    }

    static func saveSummary(_ summary: RecordingSummary, for recording: Recording) {
        let url = summaryURL(for: recording)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(summary) {
            try? data.write(to: url)
        }
    }

    static func summaryURL(for recording: Recording) -> URL {
        recording.fileURL.deletingPathExtension().appendingPathExtension("summary.json")
    }

    // MARK: - Private

    private static func parseSummaryJSON(_ response: String) throws -> RecordingSummary {
        // Models wrap JSON in think blocks, code fences, or commentary — peel
        // all of it off and isolate the first balanced JSON object.
        var jsonString = response
            .strippingThinkBlocks()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences if present
        if jsonString.hasPrefix("```") {
            let lines = jsonString.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.hasPrefix("```") }
            jsonString = filtered.joined(separator: "\n")
        }

        // If there's leading/trailing prose, extract the first balanced {...}.
        if !jsonString.hasPrefix("{"), let extracted = firstBalancedJSONObject(in: jsonString) {
            jsonString = extracted
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw SummarizationError.invalidResponse("Could not convert response to data")
        }

        // Try to decode the full structure (new fields optional — smaller local
        // models sometimes omit them).
        struct RawSummary: Decodable {
            let summary: String
            let actionItems: [String]?
            let generatedName: String
            let keyPoints: [String]?
            let decisions: [String]?
            let topics: [String]?
        }

        do {
            let raw = try JSONDecoder().decode(RawSummary.self, from: data)
            return RecordingSummary(
                summary: raw.summary,
                actionItems: raw.actionItems ?? [],
                generatedName: raw.generatedName,
                generatedAt: .now,
                keyPoints: raw.keyPoints,
                decisions: raw.decisions,
                topics: raw.topics
            )
        } catch {
            throw SummarizationError.invalidResponse("Failed to parse summary JSON: \(error.localizedDescription)")
        }
    }

    /// Extracts the first balanced `{…}` object, respecting strings/escapes.
    private static func firstBalancedJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if escaped {
                escaped = false
            } else if inString {
                if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else {
                switch char {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

enum SummarizationError: LocalizedError {
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let msg): return "Summary error: \(msg)"
        }
    }
}
