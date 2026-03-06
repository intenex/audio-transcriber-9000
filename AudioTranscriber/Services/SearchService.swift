import Foundation
import Observation

@Observable
final class SearchService {
    var searchQuery = ""
    var searchResults: [SearchResult] = []
    var isSearching = false
    var useNaturalLanguage = false

    struct SearchResult: Identifiable {
        let id = UUID()
        let recordingID: UUID
        let recordingName: String
        let matchedSnippet: String
        let matchCount: Int
    }

    // MARK: - Exact Search

    func searchExact(query: String, recordings: [Recording]) -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        let lowered = query.lowercased()
        var results: [SearchResult] = []

        for recording in recordings {
            var matchCount = 0
            var snippet = ""

            // Check display name
            if recording.displayName.lowercased().contains(lowered) {
                matchCount += 1
            }

            // Check transcript content
            if let transcriptURL = recording.transcriptionURL,
               let content = try? String(contentsOf: transcriptURL, encoding: .utf8) {
                let contentLowered = content.lowercased()
                var searchRange = contentLowered.startIndex..<contentLowered.endIndex
                while let range = contentLowered.range(of: lowered, range: searchRange) {
                    matchCount += 1
                    if snippet.isEmpty {
                        // Extract context around first match
                        let matchStart = content.distance(from: content.startIndex, to: range.lowerBound)
                        let contextStart = max(0, matchStart - 40)
                        let contextEnd = min(content.count, matchStart + query.count + 40)
                        let startIdx = content.index(content.startIndex, offsetBy: contextStart)
                        let endIdx = content.index(content.startIndex, offsetBy: contextEnd)
                        snippet = String(content[startIdx..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if contextStart > 0 { snippet = "..." + snippet }
                        if contextEnd < content.count { snippet += "..." }
                    }
                    searchRange = range.upperBound..<contentLowered.endIndex
                }
            }

            if matchCount > 0 {
                results.append(SearchResult(
                    recordingID: recording.id,
                    recordingName: recording.displayName,
                    matchedSnippet: snippet,
                    matchCount: matchCount
                ))
            }
        }

        return results.sorted { $0.matchCount > $1.matchCount }
    }

    // MARK: - Natural Language Search

    func searchNaturalLanguage(query: String, recordings: [Recording], llm: LLMService) async -> [SearchResult] {
        guard !query.isEmpty, llm.isAvailable else { return [] }

        // First pass: build manifest of recordings with summaries
        var manifest = "Available recordings:\n"
        for recording in recordings {
            manifest += "- ID: \(recording.id), Name: \(recording.displayName)"
            if let transcriptURL = recording.transcriptionURL,
               let content = try? String(contentsOf: transcriptURL, encoding: .utf8) {
                let preview = String(content.prefix(200))
                manifest += ", Preview: \(preview)"
            }
            manifest += "\n"
        }

        let prompt = """
        Given these recordings:
        \(manifest)

        The user is searching for: "\(query)"

        List the IDs of the most relevant recordings, one per line, most relevant first.
        Only list recording IDs, nothing else.
        """

        do {
            let response = try await llm.generate(prompt: prompt, system: "You are a search assistant. Respond with only recording IDs, one per line.")
            let ids = response.components(separatedBy: .newlines)
                .compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }

            return ids.compactMap { id in
                guard let recording = recordings.first(where: { $0.id == id }) else { return nil }
                return SearchResult(
                    recordingID: recording.id,
                    recordingName: recording.displayName,
                    matchedSnippet: "Matched by AI search",
                    matchCount: 1
                )
            }
        } catch {
            return []
        }
    }
}
