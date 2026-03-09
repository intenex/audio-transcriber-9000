import Foundation
import Observation

@Observable
final class LLMService {
    var isAvailable = false
    var isChecking = false

    var selectedModel: String {
        get { UserDefaults.standard.string(forKey: "llmModel") ?? "mlx-community/Mistral-7B-Instruct-v0.3-4bit" }
        set { UserDefaults.standard.set(newValue, forKey: "llmModel") }
    }

    // MARK: - Availability

    func checkAvailability() async {
        await MainActor.run { isChecking = true }
        defer { Task { @MainActor in isChecking = false } }

        let condaPath = resolveCondaPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: condaPath)
        process.arguments = ["run", "-n", "transcriber", "python", "-c", "import mlx_lm"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let available = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }

        await MainActor.run { isAvailable = available }
    }

    // MARK: - Generate (non-streaming)

    func generate(prompt: String, system: String? = nil) async throws -> String {
        guard isAvailable else { throw LLMError.notAvailable }
        let messages: [[String: String]] = [["role": "user", "content": prompt]]
        return try await runProcess(messages: messages, system: system)
    }

    // MARK: - Chat (streaming)

    func chat(messages: [[String: String]], system: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard self.isAvailable else { throw LLMError.notAvailable }

                    let process = try self.makeProcess(messages: messages, system: system)
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                        continuation.yield(text)
                    }

                    process.terminationHandler = { proc in
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        if proc.terminationStatus == 0 {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: LLMError.processFailed("Exit \(proc.terminationStatus)"))
                        }
                    }

                    try process.run()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private func runProcess(messages: [[String: String]], system: String?) async throws -> String {
        let process = try makeProcess(messages: messages, system: system)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let errText = String(data: errData, encoding: .utf8) ?? ""
                    let msg = errText.isEmpty ? "Exit \(proc.terminationStatus)" : errText
                    continuation.resume(throwing: LLMError.processFailed(msg))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func makeProcess(messages: [[String: String]], system: String?) throws -> Process {
        let condaPath = resolveCondaPath()
        let scriptPath = resolveScriptPath()

        let messagesData = try JSONSerialization.data(withJSONObject: messages)
        guard let messagesJSON = String(data: messagesData, encoding: .utf8) else {
            throw LLMError.encodingFailed
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: condaPath)
        var args = [
            "run", "-n", "transcriber", "--no-capture-output",
            "python", scriptPath,
            "--messages", messagesJSON,
            "--model", selectedModel,
            "--max-tokens", "800",
        ]
        if let system {
            args.append(contentsOf: ["--system", system])
        }
        process.arguments = args
        return process
    }

    private func resolveCondaPath() -> String {
        let candidates = [
            NSHomeDirectory() + "/miniconda3/condabin/conda",
            NSHomeDirectory() + "/anaconda3/condabin/conda",
            NSHomeDirectory() + "/miniforge3/condabin/conda",
            "/opt/homebrew/Caskroom/miniconda/base/condabin/conda",
            "/usr/local/Caskroom/miniconda/base/condabin/conda",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/usr/bin/env"
    }

    private func resolveScriptPath() -> String {
        let fm = FileManager.default

        if let bundlePath = Bundle.main.resourcePath {
            let candidate = (bundlePath as NSString).appendingPathComponent("scripts/generate.py")
            if fm.fileExists(atPath: candidate) { return candidate }
        }

        let cwdCandidate = fm.currentDirectoryPath + "/scripts/generate.py"
        if fm.fileExists(atPath: cwdCandidate) { return cwdCandidate }

        let appDir = Bundle.main.bundleURL.deletingLastPathComponent().path
        let appDirCandidate = appDir + "/scripts/generate.py"
        if fm.fileExists(atPath: appDirCandidate) { return appDirCandidate }

        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("scripts/generate.py").path
            if fm.fileExists(atPath: candidate) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        let knownPath = NSHomeDirectory() + "/Dropbox/code/audio-transcriber/scripts/generate.py"
        if fm.fileExists(atPath: knownPath) { return knownPath }

        return appDir + "/scripts/generate.py"
    }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case notAvailable
    case processFailed(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "AI model not available. Install mlx-lm in the transcriber conda environment."
        case .processFailed(let msg):
            return "AI generation failed: \(msg)"
        case .encodingFailed:
            return "Failed to encode messages for AI generation."
        }
    }
}
