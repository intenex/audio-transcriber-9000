import Foundation
import Observation

@Observable
final class TranscriptionService {
    var isTranscribing = false
    var progress: String = ""
    var progressPercent: Double = 0
    var errorMessage: String? = nil

    // MARK: - Public

    func transcribe(recording: inout Recording) async {
        let hfToken = UserDefaults.standard.string(forKey: "huggingFaceToken") ?? ""
        let model = UserDefaults.standard.string(forKey: "whisperModel") ?? "large-v3"

        guard !hfToken.isEmpty else {
            recording.status = .failed
            errorMessage = "HuggingFace token not set. Open Settings to configure it."
            return
        }

        await MainActor.run {
            isTranscribing = true
            progress = "Starting transcription..."
            progressPercent = 0
            recording.status = .processing
        }

        do {
            let json = try await runPythonScript(
                audioPath: recording.fileURL.path,
                hfToken: hfToken,
                model: model
            )

            let result = try parseJSON(json)

            let markdownURL = recording.fileURL.deletingPathExtension().appendingPathExtension("md")
            let markdown = MarkdownFormatter.format(result: result, recording: recording)
            try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

            // Save word-level segment data for interactive playback
            let segmentsURL = recording.fileURL.deletingPathExtension().appendingPathExtension("segments.json")
            if let segData = try? JSONEncoder().encode(result.segments) {
                try? segData.write(to: segmentsURL)
            }

            await MainActor.run {
                recording.transcriptionURL = markdownURL
                recording.status = .done
                isTranscribing = false
                progress = ""
                progressPercent = 0
            }

            // Auto-summarize if Ollama is available
            await autoSummarize(transcript: markdown, recording: &recording)
        } catch {
            await MainActor.run {
                recording.status = .failed
                errorMessage = error.localizedDescription
                isTranscribing = false
                progress = ""
                progressPercent = 0
            }
        }
    }

    // MARK: - Auto Summarization

    private func autoSummarize(transcript: String, recording: inout Recording) async {
        let llm = LLMService()
        await llm.checkAvailability()
        guard llm.isAvailable else { return }

        await MainActor.run { progress = "Generating summary..." }

        do {
            let summary = try await SummarizationService.summarize(transcript: transcript, llm: llm)
            SummarizationService.saveSummary(summary, for: recording)

            // Auto-name if no name set
            if recording.name == nil {
                await MainActor.run {
                    recording.name = summary.generatedName
                }
            }
        } catch {
            // Non-fatal: summarization failure shouldn't affect transcription success
        }
    }

    // MARK: - Private

    private func runPythonScript(audioPath: String, hfToken: String, model: String) async throws -> String {
        let scriptPath = resolveScriptPath()

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        let condaPath = resolveCondaPath()
        process.executableURL = URL(fileURLWithPath: condaPath)
        process.arguments = [
            "run", "-n", "transcriber", "--no-capture-output",
            "python", scriptPath,
            audioPath, hfToken,
            "--model", model,
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        // Read stderr asynchronously for progress updates
        var stderrAccumulator = ""
        let stderrHandle = stderr.fileHandleForReading
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            stderrAccumulator += line

            // Parse PROGRESS lines
            for part in line.components(separatedBy: "\n") {
                if part.hasPrefix("PROGRESS:") {
                    let components = part.dropFirst("PROGRESS:".count).components(separatedBy: ":")
                    if components.count >= 2,
                       let percent = Double(components[0]) {
                        let message = components.dropFirst().joined(separator: ":")
                        Task { @MainActor [weak self] in
                            self?.progressPercent = percent / 100.0
                            self?.progress = message
                        }
                    }
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                stderrHandle.readabilityHandler = nil
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8) ?? ""

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    let msg = stderrAccumulator.isEmpty ? "Transcription process failed (exit \(proc.terminationStatus))" : stderrAccumulator
                    continuation.resume(throwing: TranscriptionError.processFailed(msg))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func parseJSON(_ json: String) throws -> TranscriptionResult {
        // Extract JSON from output — log lines may leak to stdout before the JSON
        let lines = json.components(separatedBy: "\n")
        let jsonString = lines.last(where: { $0.hasPrefix("{") }) ?? json

        guard let data = jsonString.data(using: .utf8) else {
            throw TranscriptionError.invalidOutput("Could not convert output to data")
        }

        // Check for error key first
        if let errorDict = try? JSONDecoder().decode([String: String].self, from: data),
           let errorMsg = errorDict["error"] {
            throw TranscriptionError.scriptError(errorMsg)
        }

        do {
            return try JSONDecoder().decode(TranscriptionResult.self, from: data)
        } catch {
            throw TranscriptionError.invalidOutput("JSON parse error: \(error.localizedDescription)\nRaw: \(json.prefix(500))")
        }
    }

    private func resolveCondaPath() -> String {
        // Check common conda locations
        let candidates = [
            NSHomeDirectory() + "/miniconda3/condabin/conda",
            NSHomeDirectory() + "/anaconda3/condabin/conda",
            NSHomeDirectory() + "/miniforge3/condabin/conda",
            "/opt/homebrew/Caskroom/miniconda/base/condabin/conda",
            "/usr/local/Caskroom/miniconda/base/condabin/conda",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        // Fallback to PATH (works in terminal but not from Xcode)
        return "/usr/bin/env"
    }

    private func resolveScriptPath() -> String {
        let fm = FileManager.default

        // 1. Check in app bundle resources
        if let bundlePath = Bundle.main.resourcePath {
            let candidate = (bundlePath as NSString).appendingPathComponent("scripts/transcribe.py")
            if fm.fileExists(atPath: candidate) { return candidate }
        }

        // 2. Check relative to current working directory
        let cwdCandidate = fm.currentDirectoryPath + "/scripts/transcribe.py"
        if fm.fileExists(atPath: cwdCandidate) { return cwdCandidate }

        // 3. Check next to the app bundle (for archived/exported apps)
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent().path
        let appDirCandidate = appDir + "/scripts/transcribe.py"
        if fm.fileExists(atPath: appDirCandidate) { return appDirCandidate }

        // 4. Walk up from app bundle to find the source project directory
        //    (handles DerivedData builds: .../Build/Products/Debug/App.app)
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("scripts/transcribe.py").path
            if fm.fileExists(atPath: candidate) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        // 5. Known project source path (development fallback)
        let knownPath = NSHomeDirectory() + "/Dropbox/code/audio-transcriber/scripts/transcribe.py"
        if fm.fileExists(atPath: knownPath) { return knownPath }

        // Last resort
        return appDir + "/scripts/transcribe.py"
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case processFailed(String)
    case invalidOutput(String)
    case scriptError(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let msg): return "Process failed: \(msg)"
        case .invalidOutput(let msg): return "Invalid output: \(msg)"
        case .scriptError(let msg): return "Script error: \(msg)"
        }
    }
}
