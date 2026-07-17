import AVFoundation
import Foundation

enum CloudTranscriptionError: LocalizedError {
    case missingAPIKey(String)
    case audioEncodingFailed(String)
    case unauthorized
    case rateLimited
    case payloadTooLarge
    case serverError(Int, String)
    case network(String)
    case invalidResponse(String)
    case providerFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "\(provider) API key not set. Add it in Settings → Transcription."
        case .audioEncodingFailed(let msg): return msg
        case .unauthorized: return "Authentication failed — check your API key in Settings."
        case .rateLimited: return "Rate limited by the provider. Try again shortly."
        case .payloadTooLarge: return "Upload too large for the provider."
        case .serverError(let status, let msg): return "Provider error (HTTP \(status)): \(msg)"
        case .network(let msg): return "Network error: \(msg)"
        case .invalidResponse(let msg): return "Unexpected provider response: \(msg)"
        case .providerFailed(let msg): return msg
        }
    }
}

/// Cloud transcription via OpenAI `gpt-4o-transcribe-diarize`: native
/// diarization, known-speaker references (enrolled voices come back already
/// named), automatic compression, and >25MB part splitting with speaker
/// continuity across parts.
final class OpenAITranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let id = "cloud.openai.gpt-4o-transcribe-diarize"
    let kind = TranscriptionEngineKind.openAI
    let modelDescription = "OpenAI · gpt-4o-transcribe-diarize"

    static let model = "gpt-4o-transcribe-diarize"
    static let maxKnownSpeakers = 4
    static let maxReferenceClipSeconds = 10.0

    private let secrets: SecretsStore
    private let session: URLSession

    init(secrets: SecretsStore = KeychainStore.shared, session: URLSession = .shared) {
        self.secrets = secrets
        self.session = session
    }

    func prepare(progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws {
        guard secrets.has(.openAI) else {
            throw CloudTranscriptionError.missingAPIKey("OpenAI")
        }
    }

    func transcribe(_ request: TranscriptionRequest,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void)
        async throws -> TranscriptionOutput {
        guard let key = secrets.get(.openAI), !key.isEmpty else {
            throw CloudTranscriptionError.missingAPIKey("OpenAI")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-upload-\(request.recordingID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let parts = AudioSplitPlanner.plan(durationSeconds: request.durationSeconds)
        var merger = PartMerger(enrolledNames: Set(request.knownSpeakers.map(\.name)))
        var allSegments: [TranscriptionSegment] = []

        // References for part 1: enrolled voices from the speaker library.
        var references: [(name: String, fileURL: URL)] = request.knownSpeakers
            .prefix(Self.maxKnownSpeakers)
            .map { ($0.name, $0.clipURL) }

        for part in parts {
            try Task.checkCancellation()
            progress(TranscriptionProgress(
                phase: .compressing,
                fractionComplete: overallFraction(part: part.index, of: parts.count, phase: 0),
                message: parts.count > 1 ? "Compressing part \(part.index + 1) of \(parts.count)…" : "Compressing audio…"))

            let partURL = workDir.appendingPathComponent("part-\(part.index).m4a")
            let timeRange = parts.count > 1 ? CMTimeRange(
                start: CMTime(seconds: part.startSeconds, preferredTimescale: 600),
                end: CMTime(seconds: part.endSeconds, preferredTimescale: 600)) : nil
            _ = try await AudioCompressor.compress(source: request.audioURL, timeRange: timeRange, to: partURL)

            try Task.checkCancellation()
            progress(TranscriptionProgress(
                phase: .uploading(part: part.index + 1, of: parts.count),
                fractionComplete: overallFraction(part: part.index, of: parts.count, phase: 1),
                message: parts.count > 1 ? "Uploading part \(part.index + 1) of \(parts.count)…" : "Uploading audio…"))

            let response = try await sendPart(fileURL: partURL, apiKey: key, references: references,
                                              partLabel: "\(part.index + 1)/\(parts.count)", progress: { frac in
                progress(TranscriptionProgress(
                    phase: .uploading(part: part.index + 1, of: parts.count),
                    fractionComplete: self.overallFraction(part: part.index, of: parts.count, phase: 1 + frac * 0.5),
                    message: "Uploading part \(part.index + 1) of \(parts.count)… \(Int(frac * 100))%"))
            })

            progress(TranscriptionProgress(
                phase: .waitingForProvider,
                fractionComplete: overallFraction(part: part.index, of: parts.count, phase: 2),
                message: "Transcribing part \(part.index + 1) of \(parts.count)…"))

            allSegments.append(contentsOf: merger.merge(segments: response.segments, offsetSeconds: part.startSeconds))

            // Build continuity references for the next part: enrolled speakers
            // plus clips of speakers already heard, capped at 4.
            if part.index < parts.count - 1 {
                references = try await buildContinuityReferences(
                    request: request, merger: &merger, segments: allSegments, workDir: workDir)
            }
        }

        progress(TranscriptionProgress(phase: .finalizing, fractionComplete: 0.98, message: "Building transcript…"))

        let result = TranscriptionResult(
            segments: allSegments,
            language: request.language ?? "auto",
            numSpeakers: Set(allSegments.map(\.speaker)).count)
        return TranscriptionOutput(result: result, speakerNames: merger.speakerNames, speakerEmbeddings: [:])
    }

    private func overallFraction(part: Int, of total: Int, phase: Double) -> Double {
        // Each part gets an equal slice; phase 0=compress start, 1=upload, 2=waiting, 3=done.
        let slice = 0.95 / Double(total)
        return min(0.97, Double(part) * slice + phase / 3 * slice)
    }

    // MARK: - Request

    private func sendPart(fileURL: URL, apiKey: String,
                          references: [(name: String, fileURL: URL)],
                          partLabel: String,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizedJSONResponse {
        var form = MultipartFormData()
        form.addField(name: "model", value: Self.model)
        form.addField(name: "response_format", value: "diarized_json")
        form.addField(name: "chunking_strategy", value: "auto")
        for ref in references.prefix(Self.maxKnownSpeakers) {
            guard let clipData = try? Data(contentsOf: ref.fileURL) else { continue }
            form.addField(name: "known_speaker_names[]", value: ref.name)
            form.addField(name: "known_speaker_references[]",
                          value: "data:audio/mp4;base64,\(clipData.base64EncodedString())")
        }
        let audioData = try Data(contentsOf: fileURL)
        guard audioData.count <= CloudAudioSpec.uploadLimitBytes else {
            throw CloudTranscriptionError.payloadTooLarge
        }
        form.addFile(name: "file", filename: fileURL.lastPathComponent, mimeType: "audio/mp4", data: audioData)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 1_800   // server processes before responding

        let body = form.encoded()

        // Retry 429/5xx twice with backoff.
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.upload(for: request, from: body)
                guard let http = response as? HTTPURLResponse else {
                    throw CloudTranscriptionError.network("invalid response")
                }
                switch http.statusCode {
                case 200:
                    do {
                        return try JSONDecoder().decode(DiarizedJSONResponse.self, from: data)
                    } catch {
                        throw CloudTranscriptionError.invalidResponse(
                            String(data: data.prefix(300), encoding: .utf8) ?? "undecodable")
                    }
                case 401, 403:
                    throw CloudTranscriptionError.unauthorized
                case 413:
                    throw CloudTranscriptionError.payloadTooLarge
                case 429, 500...599:
                    if attempt <= 2 {
                        try await Task.sleep(for: .seconds(attempt == 1 ? 2 : 8))
                        continue
                    }
                    let message = (try? JSONDecoder().decode(OpenAIErrorBody.self, from: data))?.error?.message
                    throw http.statusCode == 429
                        ? CloudTranscriptionError.rateLimited
                        : CloudTranscriptionError.serverError(http.statusCode, message ?? "server error")
                default:
                    let message = (try? JSONDecoder().decode(OpenAIErrorBody.self, from: data))?.error?.message
                    throw CloudTranscriptionError.serverError(http.statusCode, message ?? "unexpected status")
                }
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                if attempt <= 2 {
                    try await Task.sleep(for: .seconds(attempt == 1 ? 2 : 8))
                    continue
                }
                throw CloudTranscriptionError.network(error.localizedDescription)
            }
        }
    }

    // MARK: - Continuity

    private func buildContinuityReferences(
        request: TranscriptionRequest, merger: inout PartMerger,
        segments: [TranscriptionSegment], workDir: URL
    ) async throws -> [(name: String, fileURL: URL)] {
        var references: [(name: String, fileURL: URL)] = []

        // Enrolled speakers already confirmed keep their real-name references.
        for known in request.knownSpeakers where merger.speakerNames.values.contains(known.name) {
            references.append((known.name, known.clipURL))
        }

        // Un-named speakers: extract their single longest clean segment ≥3s as a clip.
        let unnamed = merger.canonicalSpeakers.filter { merger.speakerNames[$0] == nil }
        // Rank by cumulative speaking time.
        let speakingTime = Dictionary(grouping: segments, by: \.speaker)
            .mapValues { $0.reduce(0) { $0 + ($1.end - $1.start) } }
        let ranked = unnamed.sorted { (speakingTime[$0] ?? 0) > (speakingTime[$1] ?? 0) }

        for canonical in ranked where references.count < Self.maxKnownSpeakers {
            guard let best = segments
                .filter({ $0.speaker == canonical && ($0.end - $0.start) >= 3 })
                .max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { continue }

            let clipEnd = min(best.end, best.start + Self.maxReferenceClipSeconds)
            let token = merger.continuityToken(for: canonical)
            let clipURL = workDir.appendingPathComponent("ref-\(token).m4a")
            let range = CMTimeRange(
                start: CMTime(seconds: best.start, preferredTimescale: 600),
                end: CMTime(seconds: clipEnd, preferredTimescale: 600))
            do {
                _ = try await AudioCompressor.compress(source: request.audioURL, timeRange: range, to: clipURL)
                merger.registerAlias(label: token, canonical: canonical)
                references.append((token, clipURL))
            } catch {
                continue // clip extraction failure just weakens continuity, not fatal
            }
        }
        return Array(references.prefix(Self.maxKnownSpeakers))
    }
}
