import Foundation

/// Pure per-file-type conflict policies. The CloudSyncManager sweep feeds
/// NSFileVersion contents through these; tests feed them directly.
///
/// | File                       | Policy                                     |
/// |----------------------------|--------------------------------------------|
/// | .meta.json                 | newest `updatedAt` wins (LWW)              |
/// | .speakers.json             | dictionary union; newer FILE wins per key  |
/// | library.json (categories)  | union of categories, newest updatedAt      |
/// | SpeakerLibrary/library.json| per-speaker merge by id (union clips/IDs)  |
/// | .md/.segments/.summary/.chat/audio | newest modification date wins      |
/// | recordings.json            | not in the synced tree (rebuildable cache) |
enum ConflictResolver {

    static func mergeMeta(_ a: RecordingMeta, _ b: RecordingMeta) -> RecordingMeta {
        a.updatedAt >= b.updatedAt ? a : b
    }

    /// Union; where both edited the same speaker id, the NEWER file's value
    /// wins. `aNewer` = whether `a` has the later modification date.
    static func mergeSpeakerNames(_ a: [String: String], _ b: [String: String],
                                  aNewer: Bool) -> [String: String] {
        let (winner, loser) = aNewer ? (a, b) : (b, a)
        return winner.merging(loser) { winnerValue, _ in winnerValue }
    }

    static func mergeCategories(_ a: LibraryFile, _ b: LibraryFile) -> LibraryFile {
        let (first, second) = a.updatedAt >= b.updatedAt ? (a, b) : (b, a)
        var categories = first.categories
        for cat in second.categories where !categories.contains(cat) {
            categories.append(cat)
        }
        return LibraryFile(categories: categories, updatedAt: max(a.updatedAt, b.updatedAt))
    }

    /// Union of speakers by id; when both sides carry the same speaker, the
    /// newer `updatedAt` wins its scalar fields and clips/recordingIDs union.
    static func mergeEnrolledSpeakers(_ a: [EnrolledSpeaker], _ b: [EnrolledSpeaker]) -> [EnrolledSpeaker] {
        var byID: [UUID: EnrolledSpeaker] = [:]
        for speaker in a { byID[speaker.id] = speaker }
        for speaker in b {
            guard let existing = byID[speaker.id] else {
                byID[speaker.id] = speaker
                continue
            }
            var (winner, loser) = existing.updatedAt >= speaker.updatedAt
                ? (existing, speaker) : (speaker, existing)
            for clip in loser.clips where !winner.clips.contains(clip) {
                winner.clips.append(clip)
            }
            for embedding in loser.embeddings where !winner.embeddings.contains(embedding) {
                winner.embeddings.append(embedding)
            }
            for id in loser.recordingIDs where !winner.recordingIDs.contains(id) {
                winner.recordingIDs.append(id)
            }
            byID[winner.id] = winner
        }
        return byID.values.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - NSFileVersion sweep

    /// Resolve any unresolved conflict versions at `url` with the policy for
    /// its file type. Content types keep the newest version; structured
    /// sidecars are MERGED and rewritten. Safe no-op when nothing conflicts.
    static func resolveConflicts(at url: URL) {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !versions.isEmpty else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let name = url.lastPathComponent
        if name.hasSuffix(".meta.json") {
            var best = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(RecordingMeta.self, from: $0) }
            for version in versions {
                if let data = try? Data(contentsOf: version.url),
                   let meta = try? decoder.decode(RecordingMeta.self, from: data) {
                    best = best.map { mergeMeta($0, meta) } ?? meta
                }
            }
            if let best, let data = try? encoder.encode(best) {
                try? AtomicFile.write(data, to: url)
            }
        } else if name.hasSuffix(".speakers.json") {
            var current = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([String: String].self, from: $0) } ?? [:]
            let currentDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            for version in versions {
                if let data = try? Data(contentsOf: version.url),
                   let names = try? decoder.decode([String: String].self, from: data) {
                    let versionDate = version.modificationDate ?? .distantPast
                    current = mergeSpeakerNames(current, names, aNewer: currentDate >= versionDate)
                }
            }
            if let data = try? encoder.encode(current) {
                try? AtomicFile.write(data, to: url)
            }
        } else if name == "library.json" && !url.deletingLastPathComponent().lastPathComponent.contains("SpeakerLibrary") {
            var current = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(LibraryFile.self, from: $0) }
            for version in versions {
                if let data = try? Data(contentsOf: version.url),
                   let file = try? decoder.decode(LibraryFile.self, from: data) {
                    current = current.map { mergeCategories($0, file) } ?? file
                }
            }
            if let current, let data = try? encoder.encode(current) {
                try? AtomicFile.write(data, to: url)
            }
        } else {
            // Content files (.md/.segments/.summary/.chat/audio): keep newest.
            let currentDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let newest = versions.max(by: { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }),
               let newestDate = newest.modificationDate, newestDate > currentDate {
                _ = try? newest.replaceItem(at: url)
            }
        }

        for version in versions { version.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
}
