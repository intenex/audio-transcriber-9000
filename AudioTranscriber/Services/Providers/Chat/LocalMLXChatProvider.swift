import Foundation

/// Local mlx-lm chat via the conda `transcriber` env. Runs `generate.py --server`
/// as a persistent child process (model loads once, stays warm); falls back to
/// one-shot invocations if the server handshake fails.
///
/// Fixes over the old LLMService: stderr is always drained (no pipe deadlock),
/// stream cancellation terminates the child, and the model isn't reloaded per call.
final class LocalMLXChatProvider: ChatProvider {
    let id = ChatProviderID.localMLX
    let displayName = "Local (MLX)"
    let contextCharacterBudget = 6_000

    /// True once `import mlx_lm` has been verified.
    private(set) var isAvailable = false

    var isConfigured: Bool { isAvailable }

    var selectedModel: String {
        get { UserDefaults.standard.string(forKey: "llmModel") ?? "mlx-community/Mistral-7B-Instruct-v0.3-4bit" }
        set { UserDefaults.standard.set(newValue, forKey: "llmModel") }
    }

    private let server = MLXServerProcess()

    // MARK: - Availability

    func checkAvailability() async -> Bool {
        guard let condaPath = CondaEnvironment.resolveCondaPath() else {
            isAvailable = false
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: condaPath)
        process.arguments = ["run", "-n", CondaEnvironment.envName, "python", "-c", "import mlx_lm"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let available = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
        isAvailable = available
        return available
    }

    // MARK: - Chat

    func streamChat(messages: [[String: String]], system: String?)
        -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let model = selectedModel
            let task = Task {
                do {
                    guard self.isAvailable else {
                        throw ChatProviderError.notAvailable(
                            "Local AI isn't available. Install mlx-lm in the transcriber conda environment.")
                    }
                    try await self.server.stream(messages: messages, system: system, model: model) { token in
                        continuation.yield(.token(token))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                task.cancel()
                if case .cancelled = termination {
                    Task { await self.server.interrupt() }
                }
            }
        }
    }
}

// MARK: - Persistent server process

/// Owns the long-lived `generate.py --server` child. Requests are serialized
/// (actor); the child is restarted on crash or model change.
actor MLXServerProcess {
    static let endMarker = "\u{1E}<<END:"
    static let readyMarker = "\u{1E}<<READY>>"

    private var process: Process? = nil
    private var stdinHandle: FileHandle? = nil
    private var stdoutBuffer = ""
    private var outputContinuation: AsyncStream<String>.Continuation? = nil
    private var outputStream: AsyncStream<String>? = nil
    private var loadedModel: String? = nil

    func interrupt() {
        // Kill the child on stream cancellation; next request restarts it.
        teardown()
    }

    private func teardown() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        stdinHandle = nil
        outputContinuation?.finish()
        outputContinuation = nil
        outputStream = nil
        stdoutBuffer = ""
        loadedModel = nil
    }

    private func ensureServer(model: String) async throws {
        if let process, process.isRunning, loadedModel == model { return }
        teardown()

        guard let condaPath = CondaEnvironment.resolveCondaPath(),
              let scriptPath = CondaEnvironment.resolveScript(named: "generate.py") else {
            throw ChatProviderError.notAvailable("Local AI environment not found (conda or generate.py missing).")
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: condaPath)
        child.arguments = [
            "run", "-n", CondaEnvironment.envName, "--no-capture-output",
            "python", "-u", scriptPath, "--server", "--model", model,
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        outputStream = stream
        outputContinuation = continuation

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            continuation.yield(text)
        }
        // Drain stderr continuously so the child can never block on a full pipe.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        child.terminationHandler = { _ in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
        }

        try child.run()
        process = child
        stdinHandle = stdinPipe.fileHandleForWriting

        // Wait for READY (model load can take ~10-60s on first run).
        let ready = try await waitForMarker(Self.readyMarker, timeout: 300)
        guard ready else {
            teardown()
            throw ChatProviderError.notAvailable("Local AI model failed to load.")
        }
        loadedModel = model
    }

    private func waitForMarker(_ marker: String, timeout: TimeInterval) async throws -> Bool {
        guard let outputStream else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        for await chunk in outputStream {
            stdoutBuffer += chunk
            if stdoutBuffer.contains(marker) {
                stdoutBuffer = ""
                return true
            }
            if Date() > deadline { return false }
        }
        return false
    }

    func stream(messages: [[String: String]], system: String?, model: String,
                onToken: @escaping (String) -> Void) async throws {
        try await ensureServer(model: model)
        guard let stdinHandle, let outputStream else {
            throw ChatProviderError.notAvailable("Local AI server not running.")
        }

        var payload: [String: Any] = ["messages": messages, "max_tokens": 800]
        if let system { payload["system"] = system }
        let requestData = try JSONSerialization.data(withJSONObject: payload)
        stdinHandle.write(requestData)
        stdinHandle.write(Data("\n".utf8))

        stdoutBuffer = ""
        for await chunk in outputStream {
            try Task.checkCancellation()
            stdoutBuffer += chunk
            if let markerRange = stdoutBuffer.range(of: Self.endMarker) {
                // Emit everything before the marker, then parse status.
                let text = String(stdoutBuffer[..<markerRange.lowerBound])
                if !text.isEmpty { onToken(text) }
                let statusPart = String(stdoutBuffer[markerRange.upperBound...])
                stdoutBuffer = ""
                if statusPart.hasPrefix("err") {
                    let message = statusPart
                        .replacingOccurrences(of: "err:", with: "")
                        .components(separatedBy: ">>").first ?? "generation failed"
                    throw ChatProviderError.providerError("Local AI: \(message)")
                }
                return
            }
            // Safe to flush all but a marker-length tail.
            let keep = Self.endMarker.count + 32
            if stdoutBuffer.count > keep {
                let flushEnd = stdoutBuffer.index(stdoutBuffer.endIndex, offsetBy: -keep)
                let text = String(stdoutBuffer[..<flushEnd])
                stdoutBuffer = String(stdoutBuffer[flushEnd...])
                if !text.isEmpty { onToken(text) }
            }
        }
        // Stream ended without the end marker — child died mid-response.
        teardown()
        throw ChatProviderError.providerError("Local AI process exited unexpectedly.")
    }
}
