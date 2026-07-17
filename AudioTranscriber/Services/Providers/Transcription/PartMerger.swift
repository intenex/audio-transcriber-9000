import Foundation

/// Merges multi-part diarized cloud results into one transcript, keeping
/// speaker identity stable across parts. Labels returned by the provider are
/// either raw letters ("A"/"B"), enrolled real names, or continuity tokens
/// ("S1"/"S2") we sent as known-speaker references from earlier parts.
struct PartMerger {
    /// Provider label → canonical SPEAKER_%02d.
    private(set) var labelToCanonical: [String: String] = [:]
    /// Canonical ID → display name (enrolled or provider-confirmed real name).
    private(set) var speakerNames: [String: String] = [:]
    private var nextIndex = 0
    let enrolledNames: Set<String>

    init(enrolledNames: Set<String> = []) {
        self.enrolledNames = enrolledNames
    }

    /// Pre-seed an alias (e.g. continuity token "S1" → SPEAKER_00) before
    /// merging the part whose request carried that reference.
    mutating func registerAlias(label: String, canonical: String) {
        labelToCanonical[label] = canonical
    }

    mutating func canonicalID(for label: String) -> String {
        if let existing = labelToCanonical[label] { return existing }
        let canonical = String(format: "SPEAKER_%02d", nextIndex)
        nextIndex += 1
        labelToCanonical[label] = canonical
        if enrolledNames.contains(label) {
            speakerNames[canonical] = label
        }
        return canonical
    }

    /// Continuity token for a canonical speaker without a real name.
    func continuityToken(for canonical: String) -> String {
        let index = Int(canonical.replacingOccurrences(of: "SPEAKER_", with: "")) ?? 0
        return "S\(index + 1)"
    }

    /// Merge one part's segments, offsetting times to absolute.
    mutating func merge(segments: [DiarizedJSONResponse.Segment], offsetSeconds: Double) -> [TranscriptionSegment] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let canonical = canonicalID(for: segment.speaker ?? "UNKNOWN")
            return TranscriptionSegment(
                start: segment.start + offsetSeconds,
                end: segment.end + offsetSeconds,
                text: text,
                speaker: canonical,
                words: []
            )
        }
    }

    /// Canonical speakers observed so far, in first-appearance order.
    var canonicalSpeakers: [String] {
        labelToCanonical.values.sorted()
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}
