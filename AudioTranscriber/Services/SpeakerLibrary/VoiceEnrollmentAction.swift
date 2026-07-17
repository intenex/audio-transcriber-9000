import CoreMedia
import Foundation

/// Extract reference clips + embeddings for a named speaker and enroll them
/// in the voice library so they're auto-recognized in future transcripts.
/// Pure service logic shared by both platforms' rename popovers.
enum VoiceEnrollmentAction {
    @MainActor
    static func enroll(name: String, speakerID: String,
                       segments: [TranscriptionSegment],
                       audioURL: URL, recordingID: UUID,
                       engine: LocalFluidAudioEngine,
                       library: SpeakerLibraryStore) async {
        let candidates = ReferenceClipExtractor.selectCandidates(segments: segments, speakerID: speakerID)
        guard !candidates.isEmpty else { return }

        var embeddings: [[Float]] = []
        var clips: [EnrolledSpeaker.Clip] = []
        let speakerUUID = UUID()

        for (index, candidate) in candidates.enumerated() {
            // Read the samples once; they gate everything downstream.
            guard let samples = try? ReferenceClipExtractor.samples16k(
                from: audioURL, start: candidate.start, end: candidate.end),
                samples.count > 16_000 else { continue }   // at least 1s

            // Silence gate: never enroll clips/embeddings that are just
            // room noise — silent references poison recognition.
            guard ReferenceClipExtractor.isLikelySpeech(samples) else { continue }

            if let embedding = try? await engine.extractEmbedding(samples: samples) {
                embeddings.append(embedding)
            }

            // Compressed clip for cloud known-speaker references
            let clipDir = library.clipsDirectory.appendingPathComponent(speakerUUID.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)
            let clipURL = clipDir.appendingPathComponent("clip-\(index + 1).m4a")
            let range = CMTimeRange(
                start: CMTime(seconds: candidate.start, preferredTimescale: 600),
                end: CMTime(seconds: candidate.end, preferredTimescale: 600))
            if (try? await AudioCompressor.compress(source: audioURL, timeRange: range, to: clipURL)) != nil,
               // Verify the written clip actually contains the speech.
               let written = try? WindowedAudioLoader.load16kMono(from: clipURL),
               ReferenceClipExtractor.isLikelySpeech(written) {
                clips.append(EnrolledSpeaker.Clip(
                    file: "clips/\(speakerUUID.uuidString)/clip-\(index + 1).m4a",
                    duration: candidate.duration,
                    sourceRecordingID: recordingID,
                    start: candidate.start,
                    end: candidate.end))
            } else {
                try? FileManager.default.removeItem(at: clipURL)
            }
        }

        guard !embeddings.isEmpty || !clips.isEmpty else { return }
        library.enroll(name: name, embeddings: embeddings, clips: clips, recordingID: recordingID)
    }
}
