import Foundation
import FluidAudio

/// On-device transcription engine: Parakeet TDT v3 ASR + pyannote community-1
/// diarization via FluidAudio (Apple Neural Engine). Chunked, checkpointed,
/// cancellable, with realtime-factor-calibrated ETAs.
actor LocalFluidAudioEngine: TranscriptionEngine {
    nonisolated let id = "local.fluidaudio.parakeet-v3"
    nonisolated let kind = TranscriptionEngineKind.local

    static let diarizerCalibrationID = "local.fluidaudio.offline-diarizer"

    private var asrManager: AsrManager? = nil
    private var diarizer: DiarizerManager? = nil
    private var vadManager: VadManager? = nil

    // MARK: - Prepare (model download + load)

    func prepare(progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws {
        if asrManager != nil, diarizer != nil { return }

        let needsDownload = !AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory())
        if needsDownload {
            progress(TranscriptionProgress(
                phase: .downloadingModels, fractionComplete: 0,
                message: "Downloading speech models (one-time, ~1.5 GB)…"))
        } else {
            progress(TranscriptionProgress(
                phase: .preparingModels, fractionComplete: 0, message: "Loading speech models…"))
        }

        if asrManager == nil {
            let models = try await AsrModels.downloadAndLoad(version: .v3) { dp in
                progress(TranscriptionProgress(
                    phase: .downloadingModels,
                    fractionComplete: dp.fractionCompleted * 0.7,
                    message: "Downloading speech model… \(Int(dp.fractionCompleted * 100))%"))
            }
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            asrManager = manager
        }

        if diarizer == nil {
            let models = try await DiarizerModels.downloadIfNeeded { dp in
                progress(TranscriptionProgress(
                    phase: .downloadingModels,
                    fractionComplete: 0.7 + dp.fractionCompleted * 0.25,
                    message: "Downloading speaker model… \(Int(dp.fractionCompleted * 100))%"))
            }
            let manager = DiarizerManager(config: DiarizerConfig())
            manager.initialize(models: models)
            diarizer = manager
        }

        if vadManager == nil {
            // VAD is optional (used only for nicer chunk boundaries) — degrade silently.
            vadManager = try? await VadManager(config: .default)
        }
    }

    /// Release loaded models (frees ~1 GB of memory).
    func unloadModels() {
        asrManager?.cleanup()
        asrManager = nil
        diarizer?.cleanup()
        diarizer = nil
        vadManager = nil
    }

    // MARK: - Transcribe

    func transcribe(_ request: TranscriptionRequest,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void)
        async throws -> TranscriptionOutput {
        try await prepare(progress: progress)
        guard let asrManager, let diarizer else {
            throw TranscriptionEngineError.modelsNotAvailable(
                "Speech models aren't available. Check your internet connection and try again.")
        }

        // 1. Load audio (resampled to 16kHz mono Float32).
        progress(TranscriptionProgress(phase: .loadingAudio, fractionComplete: 0.01, message: "Loading audio…"))
        let samples: [Float]
        do {
            samples = try AudioConverter().resampleAudioFile(request.audioURL)
        } catch {
            throw TranscriptionEngineError.audioLoadFailed(error.localizedDescription)
        }
        let sampleRate = 16000.0
        let audioSeconds = Double(samples.count) / sampleRate
        try Task.checkCancellation()

        // 2. Resume checkpoint or plan chunks.
        let fingerprint = TranscriptionCheckpoint.fingerprint(for: request.audioURL, durationSeconds: audioSeconds)
        var checkpoint: TranscriptionCheckpoint
        if let existing = TranscriptionCheckpoint.loadIfValid(
            from: request.checkpointURL, engineID: id, fingerprint: fingerprint) {
            checkpoint = existing
        } else {
            let speech = await detectSpeechSegments(samples: samples)
            let plan = ChunkPlanner.plan(durationSeconds: audioSeconds, speechSegments: speech)
            checkpoint = TranscriptionCheckpoint(
                engineID: id, recordingID: request.recordingID,
                audioFingerprint: fingerprint, chunkPlan: plan)
        }
        try Task.checkCancellation()

        // 3. Transcribe missing chunks serially, checkpointing after each.
        let totalChunks = checkpoint.chunkPlan.count
        let etaCalc = ETACalculator(
            asrRTF: RTFStore.rtf(engineID: id),
            diarizerRTF: RTFStore.rtf(engineID: Self.diarizerCalibrationID, fallback: RTFStore.defaultDiarizer),
            totalAudioSeconds: audioSeconds)

        // Fraction budget: ASR 5%→80%, diarization 80%→95%, finalize →100%.
        func asrFraction(_ completedSeconds: Double) -> Double {
            0.05 + 0.75 * (audioSeconds > 0 ? completedSeconds / audioSeconds : 1)
        }

        if !checkpoint.asrComplete {
            for chunk in checkpoint.chunkPlan where !checkpoint.completedChunkIndices.contains(chunk.index) {
                try Task.checkCancellation()
                progress(TranscriptionProgress(
                    phase: .transcribing(chunk: chunk.index + 1, of: totalChunks),
                    fractionComplete: asrFraction(checkpoint.completedAudioSeconds),
                    message: "Transcribing part \(chunk.index + 1) of \(totalChunks)…",
                    etaSeconds: etaCalc.estimate(
                        completedAudioSeconds: checkpoint.completedAudioSeconds,
                        diarizationPending: true)))

                let startSample = min(samples.count, Int(chunk.startSeconds * sampleRate))
                let endSample = min(samples.count, Int(chunk.endSeconds * sampleRate))
                guard endSample > startSample else {
                    checkpoint.record(.init(index: chunk.index, text: "", words: [], processingSeconds: 0.01))
                    checkpoint.save(to: request.checkpointURL)
                    continue
                }

                let began = Date()
                let result = try await asrManager.transcribe(Array(samples[startSample..<endSample]), source: .system)
                let elapsed = Date().timeIntervalSince(began)

                // Word timings from tokens, offset to absolute time; interpolate if absent.
                let words: [TranscriptionWord]
                if let timings = result.tokenTimings, !timings.isEmpty {
                    words = WordTimingAssembler.words(from: timings).map {
                        TranscriptionWord(word: $0.word,
                                          start: $0.start + chunk.startSeconds,
                                          end: $0.end + chunk.startSeconds)
                    }
                } else {
                    words = TranscriptMerger.interpolateWords(
                        text: result.text, start: chunk.startSeconds, end: chunk.endSeconds
                    ).map { TranscriptionWord(word: $0.word, start: $0.start, end: $0.end) }
                }

                checkpoint.record(.init(index: chunk.index, text: result.text,
                                        words: words, processingSeconds: elapsed))
                checkpoint.save(to: request.checkpointURL)
                RTFStore.record(engineID: id, audioSeconds: chunk.duration, processingSeconds: elapsed)
            }
            checkpoint.asrComplete = true
            checkpoint.save(to: request.checkpointURL)
        }
        try Task.checkCancellation()

        // 4. Diarize the full file in one pass (global clustering).
        progress(TranscriptionProgress(
            phase: .diarizing, fractionComplete: 0.82, message: "Identifying speakers…",
            etaSeconds: etaCalc.estimate(completedAudioSeconds: audioSeconds, diarizationPending: true)))
        let diarizeBegan = Date()
        // performCompleteDiarization is synchronous and heavy — run it on a GCD
        // thread so it can't starve the Swift-concurrency cooperative pool.
        let diarization = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DiarizationResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try diarizer.performCompleteDiarization(samples, sampleRate: Int(sampleRate)))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        RTFStore.record(engineID: Self.diarizerCalibrationID,
                        audioSeconds: audioSeconds,
                        processingSeconds: Date().timeIntervalSince(diarizeBegan))
        try Task.checkCancellation()

        // 5. Assign speakers to words, merge into segments.
        progress(TranscriptionProgress(phase: .finalizing, fractionComplete: 0.96, message: "Building transcript…"))
        let allWords: [(word: String, start: Double, end: Double)] = checkpoint.chunks
            .sorted { $0.index < $1.index }
            .flatMap { $0.words }
            .compactMap { w in
                guard let s = w.start, let e = w.end else { return nil }
                return (w.word, s, e)
            }

        let turns = diarization.segments.map {
            SpeakerTurn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId)
        }
        let labeled = SpeakerAssigner.assign(words: allWords, turns: turns)
        let (normalized, mapping) = SpeakerAssigner.normalizeSpeakerIDs(labeled)
        let segments = TranscriptMerger.makeSegments(from: normalized)

        // Cluster embeddings keyed by normalized SPEAKER_XX labels (for enrollment matching).
        var embeddings: [String: [Float]] = [:]
        for segment in diarization.segments {
            if let normalizedID = mapping[segment.speakerId], embeddings[normalizedID] == nil,
               !segment.embedding.isEmpty {
                embeddings[normalizedID] = segment.embedding
            }
        }

        let result = TranscriptionResult(
            segments: segments,
            language: request.language ?? "auto",
            numSpeakers: Set(segments.map(\.speaker)).count)

        return TranscriptionOutput(result: result, speakerNames: [:], speakerEmbeddings: embeddings)
    }

    /// Extract a speaker embedding from raw audio samples (voice enrollment).
    func extractEmbedding(samples: [Float]) async throws -> [Float] {
        try await prepare(progress: { _ in })
        guard let diarizer else {
            throw TranscriptionEngineError.modelsNotAvailable("Speaker models unavailable")
        }
        return try diarizer.extractSpeakerEmbedding(from: samples)
    }

    private func detectSpeechSegments(samples: [Float]) async -> [ClosedRange<Double>] {
        guard let vadManager else { return [] }
        guard let segments = try? await vadManager.segmentSpeech(samples) else { return [] }
        return segments.compactMap { $0.endTime > $0.startTime ? $0.startTime...$0.endTime : nil }
    }
}
