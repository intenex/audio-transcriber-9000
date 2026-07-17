import Foundation

/// Cloud transcription via AssemblyAI: single upload (up to 5 GB — no client
/// splitting ever), async processing with polling, word-level speaker labels.
/// Best choice for very long recordings.
final class AssemblyAITranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let id = "cloud.assemblyai.universal"
    let kind = TranscriptionEngineKind.assemblyAI

    static let baseURL = URL(string: "https://api.assemblyai.com/v2")!
    static let pollInterval: Duration = .seconds(3)

    private let secrets: SecretsStore
    private let session: URLSession

    init(secrets: SecretsStore = KeychainStore.shared, session: URLSession = .shared) {
        self.secrets = secrets
        self.session = session
    }

    func prepare(progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws {
        guard secrets.has(.assemblyAI) else {
            throw CloudTranscriptionError.missingAPIKey("AssemblyAI")
        }
    }

    // MARK: - Response models (defensive)

    private struct UploadResponse: Decodable {
        let upload_url: String
    }

    struct TranscriptResponse: Decodable {
        struct Word: Decodable {
            let text: String
            let start: Int      // ms
            let end: Int        // ms
            let speaker: String?
        }
        struct Utterance: Decodable {
            let speaker: String?
            let start: Int
            let end: Int
            let text: String
            let words: [Word]?
        }
        let id: String
        let status: String      // queued | processing | completed | error
        let error: String?
        let utterances: [Utterance]?
        let words: [Word]?
        let language_code: String?
    }

    // MARK: - Pipeline

    func transcribe(_ request: TranscriptionRequest,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void)
        async throws -> TranscriptionOutput {
        guard let key = secrets.get(.assemblyAI), !key.isEmpty else {
            throw CloudTranscriptionError.missingAPIKey("AssemblyAI")
        }

        // 1. Compress (16kHz mono AAC — turns a 3 GB WAV into ~70 MB).
        progress(TranscriptionProgress(phase: .compressing, fractionComplete: 0.02, message: "Compressing audio…"))
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemblyai-\(request.recordingID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let compressedURL = workDir.appendingPathComponent("upload.m4a")
        _ = try await AudioCompressor.compress(source: request.audioURL, to: compressedURL)
        try Task.checkCancellation()

        // 2. Upload raw bytes.
        progress(TranscriptionProgress(phase: .uploading(part: 1, of: 1), fractionComplete: 0.15, message: "Uploading audio…"))
        var uploadRequest = URLRequest(url: Self.baseURL.appendingPathComponent("upload"))
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue(key, forHTTPHeaderField: "authorization")
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        uploadRequest.timeoutInterval = 1_800

        let (uploadData, uploadHTTPResponse) = try await session.upload(for: uploadRequest, fromFile: compressedURL)
        try Self.checkHTTP(uploadHTTPResponse, data: uploadData)
        guard let upload = try? JSONDecoder().decode(UploadResponse.self, from: uploadData) else {
            throw CloudTranscriptionError.invalidResponse("upload response undecodable")
        }
        try Task.checkCancellation()

        // 3. Create transcript job.
        progress(TranscriptionProgress(phase: .waitingForProvider, fractionComplete: 0.3, message: "Transcription queued…"))
        var createRequest = URLRequest(url: Self.baseURL.appendingPathComponent("transcript"))
        createRequest.httpMethod = "POST"
        createRequest.setValue(key, forHTTPHeaderField: "authorization")
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "audio_url": upload.upload_url,
            "speaker_labels": true,
            "language_detection": true,
        ] as [String: Any])

        let (createData, createHTTPResponse) = try await session.data(for: createRequest)
        try Self.checkHTTP(createHTTPResponse, data: createData)
        guard let created = try? JSONDecoder().decode(TranscriptResponse.self, from: createData) else {
            throw CloudTranscriptionError.invalidResponse("create response undecodable")
        }

        // 4. Poll until complete (cancellation-aware).
        let began = Date()
        var transcript = created
        while transcript.status == "queued" || transcript.status == "processing" {
            try Task.checkCancellation()
            try await Task.sleep(for: Self.pollInterval)
            let elapsed = Int(Date().timeIntervalSince(began))
            progress(TranscriptionProgress(
                phase: .waitingForProvider,
                fractionComplete: min(0.9, 0.3 + Double(elapsed) / 600 * 0.6),
                message: "Processing in the cloud… (\(elapsed)s)"))

            var pollRequest = URLRequest(url: Self.baseURL.appendingPathComponent("transcript/\(created.id)"))
            pollRequest.setValue(key, forHTTPHeaderField: "authorization")
            let (pollData, pollHTTPResponse) = try await session.data(for: pollRequest)
            try Self.checkHTTP(pollHTTPResponse, data: pollData)
            guard let polled = try? JSONDecoder().decode(TranscriptResponse.self, from: pollData) else {
                throw CloudTranscriptionError.invalidResponse("poll response undecodable")
            }
            transcript = polled
        }

        guard transcript.status == "completed" else {
            throw CloudTranscriptionError.providerFailed(transcript.error ?? "AssemblyAI job failed")
        }

        progress(TranscriptionProgress(phase: .finalizing, fractionComplete: 0.96, message: "Building transcript…"))
        let segments = Self.mapToSegments(transcript)
        let result = TranscriptionResult(
            segments: segments,
            language: transcript.language_code ?? request.language ?? "auto",
            numSpeakers: Set(segments.map(\.speaker)).count)
        return TranscriptionOutput(result: result)
    }

    // MARK: - Mapping

    static func mapToSegments(_ transcript: TranscriptResponse) -> [TranscriptionSegment] {
        // Normalize "A"/"B" speaker letters to SPEAKER_%02d in first-appearance order.
        var mapping: [String: String] = [:]
        var nextIndex = 0
        func canonical(_ label: String?) -> String {
            let raw = label ?? "UNKNOWN"
            if let existing = mapping[raw] { return existing }
            let id = String(format: "SPEAKER_%02d", nextIndex)
            nextIndex += 1
            mapping[raw] = id
            return id
        }

        if let utterances = transcript.utterances, !utterances.isEmpty {
            return utterances.map { utterance in
                TranscriptionSegment(
                    start: Double(utterance.start) / 1000,
                    end: Double(utterance.end) / 1000,
                    text: utterance.text,
                    speaker: canonical(utterance.speaker),
                    words: (utterance.words ?? []).map {
                        TranscriptionWord(word: $0.text, start: Double($0.start) / 1000, end: Double($0.end) / 1000)
                    })
            }
        }

        // Fallback: no utterances (diarization unavailable) — one segment stream from words.
        guard let words = transcript.words, !words.isEmpty else { return [] }
        let labeled = words.map {
            LabeledWord(word: $0.text, start: Double($0.start) / 1000, end: Double($0.end) / 1000,
                        speaker: canonical($0.speaker))
        }
        return TranscriptMerger.makeSegments(from: labeled)
    }

    private static func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.network("invalid response")
        }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw CloudTranscriptionError.unauthorized
        case 429: throw CloudTranscriptionError.rateLimited
        default:
            let message = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw CloudTranscriptionError.serverError(http.statusCode, message)
        }
    }
}
