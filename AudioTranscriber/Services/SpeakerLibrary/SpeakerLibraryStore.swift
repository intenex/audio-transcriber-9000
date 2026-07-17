import Foundation
import Observation

struct EnrolledSpeaker: Codable, Identifiable, Equatable {
    struct Clip: Codable, Equatable {
        var file: String                 // relative to the SpeakerLibrary dir
        var duration: Double
        var sourceRecordingID: UUID?
        var start: Double
        var end: Double
    }

    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var embeddings: [[Float]]
    var clips: [Clip]
    var recordingIDs: [UUID]
}

/// Global voice-enrollment library: named speakers with embeddings + reference
/// clips, stored under <storageDirectory>/SpeakerLibrary/. Matching against
/// diarization cluster embeddings auto-names speakers in new transcripts.
@Observable @MainActor
final class SpeakerLibraryStore {
    private struct Library: Codable {
        var version: Int = 1
        var autoMatchThreshold: Float = 0.70
        var speakers: [EnrolledSpeaker] = []
    }

    private(set) var speakers: [EnrolledSpeaker] = []
    var autoMatchThreshold: Float = 0.70 {
        didSet { save() }
    }

    private var directory: URL
    private var libraryURL: URL { directory.appendingPathComponent("library.json") }
    var clipsDirectory: URL { directory.appendingPathComponent("clips", isDirectory: true) }

    init(storageDirectory: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = storageDirectory ?? docs.appendingPathComponent("AudioTranscriber", isDirectory: true)
        directory = base.appendingPathComponent("SpeakerLibrary", isDirectory: true)
    }

    func attach(storageDirectory: URL) {
        directory = storageDirectory.appendingPathComponent("SpeakerLibrary", isDirectory: true)
        load()
    }

    func load() {
        try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: libraryURL),
              let library = try? decoder.decode(Library.self, from: data) else {
            speakers = []
            return
        }
        speakers = library.speakers
        autoMatchThreshold = library.autoMatchThreshold
    }

    func save() {
        try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        let library = Library(autoMatchThreshold: autoMatchThreshold, speakers: speakers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(library) {
            try? data.write(to: libraryURL, options: .atomic)
        }
    }

    // MARK: - Enrollment

    /// Upsert by case-insensitive name: enriches an existing speaker with new
    /// embeddings/clips instead of duplicating.
    @discardableResult
    func enroll(name: String, embeddings: [[Float]], clips: [EnrolledSpeaker.Clip],
                recordingID: UUID?) -> EnrolledSpeaker {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = speakers.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            speakers[idx].embeddings.append(contentsOf: embeddings)
            speakers[idx].clips.append(contentsOf: clips)
            if let recordingID, !speakers[idx].recordingIDs.contains(recordingID) {
                speakers[idx].recordingIDs.append(recordingID)
            }
            speakers[idx].updatedAt = .now
            save()
            return speakers[idx]
        }
        let speaker = EnrolledSpeaker(
            id: UUID(), name: trimmed, createdAt: .now, updatedAt: .now,
            embeddings: embeddings, clips: clips,
            recordingIDs: recordingID.map { [$0] } ?? [])
        speakers.append(speaker)
        save()
        return speaker
    }

    func delete(_ speaker: EnrolledSpeaker) {
        for clip in speaker.clips {
            let url = clipURL(for: clip)
            try? FileManager.default.removeItem(at: url)
            // Remove the containing directory when empty.
            let dir = url.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        speakers.removeAll { $0.id == speaker.id }
        save()
    }

    func clipURL(for clip: EnrolledSpeaker.Clip) -> URL {
        directory.appendingPathComponent(clip.file)
    }

    /// Best reference clips for cloud known-speaker hints, ranked by how many
    /// recordings the speaker has been seen in, then recency.
    func referenceCandidates(limit: Int) -> [KnownSpeakerReference] {
        let ranked = speakers
            .filter { !$0.clips.isEmpty }
            .sorted {
                if $0.recordingIDs.count != $1.recordingIDs.count {
                    return $0.recordingIDs.count > $1.recordingIDs.count
                }
                return $0.updatedAt > $1.updatedAt
            }
        return ranked.prefix(limit).compactMap { speaker in
            guard let clip = speaker.clips.max(by: { $0.duration < $1.duration }) else { return nil }
            let url = clipURL(for: clip)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return KnownSpeakerReference(name: speaker.name, clipURL: url)
        }
    }

    // MARK: - Matching

    /// Match diarization cluster embeddings against the library and write
    /// auto-identified names into the recording's .speakers.json (never
    /// overwriting existing entries). Also records recording sightings.
    func handleTranscriptionCompleted(recording: Recording, output: TranscriptionOutput) {
        guard !output.speakerEmbeddings.isEmpty, !speakers.isEmpty else { return }

        var names = (try? Data(contentsOf: recording.speakersURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        var changed = false

        for (clusterID, embedding) in output.speakerEmbeddings {
            guard names[clusterID] == nil else { continue }
            if let match = SpeakerMatcher.match(embedding: embedding, against: speakers,
                                                threshold: autoMatchThreshold) {
                names[clusterID] = match.speaker.name
                changed = true
                if let idx = speakers.firstIndex(where: { $0.id == match.speaker.id }),
                   !speakers[idx].recordingIDs.contains(recording.id) {
                    speakers[idx].recordingIDs.append(recording.id)
                    speakers[idx].updatedAt = .now
                }
            }
        }

        if changed {
            if let data = try? JSONEncoder().encode(names) {
                try? data.write(to: recording.speakersURL)
            }
            save()
        }
    }
}
