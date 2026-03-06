import Foundation

struct SummarizationService {

    static func summarize(transcript: String, llm: LLMService) async throws -> RecordingSummary {
        let prompt = """
        Given this transcript, provide a JSON response with exactly these fields:
        - "summary": A concise 2-3 paragraph summary of the key points discussed
        - "actionItems": An array of action item strings extracted from the conversation (empty array if none)
        - "generatedName": A short descriptive name for this recording (5 words max)

        Respond ONLY with valid JSON, no markdown formatting or code blocks.

        Transcript:
        \(transcript.prefix(8000))
        """

        let system = "You are a helpful assistant that analyzes meeting transcripts. Always respond with valid JSON only."

        let response = try await llm.generate(prompt: prompt, system: system)
        return try parseSummaryJSON(response)
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
        // Try to extract JSON from the response (LLM may wrap in markdown code blocks)
        var jsonString = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences if present
        if jsonString.hasPrefix("```") {
            let lines = jsonString.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.hasPrefix("```") }
            jsonString = filtered.joined(separator: "\n")
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw SummarizationError.invalidResponse("Could not convert response to data")
        }

        // Try to decode the full structure
        struct RawSummary: Decodable {
            let summary: String
            let actionItems: [String]
            let generatedName: String
        }

        do {
            let raw = try JSONDecoder().decode(RawSummary.self, from: data)
            return RecordingSummary(
                summary: raw.summary,
                actionItems: raw.actionItems,
                generatedName: raw.generatedName,
                generatedAt: .now
            )
        } catch {
            throw SummarizationError.invalidResponse("Failed to parse summary JSON: \(error.localizedDescription)")
        }
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
