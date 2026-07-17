import SwiftUI

enum ChatContext {
    case recording(Recording)
    case global
}

/// One chat implementation for both per-recording and global (all-recordings)
/// conversations, streaming through the active ChatProvider.
struct ChatSessionView: View {
    let context: ChatContext

    @Environment(ChatService.self) private var chatService
    @Environment(RecordingStore.self) private var store

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var streamingResponse = ""
    @State private var streamingReasoning = ""
    @State private var isStreaming = false
    @State private var lastError: String? = nil
    @State private var lastFailedUserMessage: String? = nil
    @State private var streamTask: Task<Void, Never>? = nil

    private var chatFileURL: URL {
        switch context {
        case .recording(let recording):
            return recording.chatURL
        case .global:
            return store.storageDirectory.appendingPathComponent(".global-chat.json")
        }
    }

    private var recordingForContext: Recording? {
        if case .recording(let recording) = context { return recording }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if case .global = context {
                globalHeader
                Divider()
            }

            if chatService.isActiveProviderReady {
                chatContent
            } else {
                providerUnavailableView
            }
        }
        .onAppear { loadChat() }
        .onDisappear { streamTask?.cancel() }
    }

    // MARK: - Header (global only)

    private var globalHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.processing.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.processing)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Chat with All Recordings")
                    .font(.headline)
                Text("\(store.recordings.count) recordings available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(chatService.activeProvider.displayName)
                .font(.caption)
                .foregroundStyle(.tertiary)

            if !messages.isEmpty {
                Button("Clear") {
                    messages = []
                    saveChat()
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Chat body

    private var chatContent: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages.filter { $0.role != .system }) { message in
                            ChatBubble(message: message)
                        }
                        if !streamingReasoning.isEmpty && streamingResponse.isEmpty {
                            HStack {
                                ProgressView().scaleEffect(0.5)
                                Text("Thinking…")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                        }
                        if !streamingResponse.isEmpty {
                            ChatBubble(message: ChatMessage(role: .assistant, content: streamingResponse))
                                .id("streaming")
                        }
                        if let error = lastError {
                            errorBubble(error)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: streamingResponse) { _, _ in
                    withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Input bar — Enter sends, Shift+Enter inserts newline
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholderText, text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) {
                            inputText.append("\n")
                            return .handled
                        }
                        sendMessage()
                        return .handled
                    }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(inputText.isEmpty || isStreaming ? Color.secondary : AppTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty || isStreaming)
            }
            .padding(12)
            .background(.bar)
        }
    }

    private var placeholderText: String {
        switch context {
        case .recording: return "Ask about this recording..."
        case .global: return "Ask about your recordings..."
        }
    }

    private func errorBubble(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warning)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.subheadline)
                    .textSelection(.enabled)
                if lastFailedUserMessage != nil {
                    Button("Retry") { retryLastMessage() }
                        .buttonStyle(.bordered)
                        .font(.caption)
                }
            }
            Spacer(minLength: 40)
        }
        .padding(10)
        .background(AppTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var providerUnavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No chat provider configured")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Add a MiniMax or OpenAI API key (or set up local mlx-lm) in Settings → AI Chat.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if chatService.activeProvider.id == .localMLX {
                Text("conda run -n transcriber pip install mlx-lm")
                    .font(.caption.monospaced())
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                Button(chatService.isCheckingLocal ? "Checking…" : "Check Again") {
                    Task { await chatService.checkLocalAvailability() }
                }
                .buttonStyle(.bordered)
                .disabled(chatService.isCheckingLocal)
            }
            SettingsLink {
                Text("Open Settings")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sending

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        inputText = ""
        lastError = nil
        lastFailedUserMessage = nil

        messages.append(ChatMessage(role: .user, content: text))
        startStream()
    }

    private func retryLastMessage() {
        guard lastFailedUserMessage != nil else { return }
        lastError = nil
        lastFailedUserMessage = nil
        startStream()
    }

    private func startStream() {
        let provider = chatService.activeProvider
        let system = buildSystemPrompt(budget: provider.contextCharacterBudget)
        var llmMessages: [[String: String]] = []
        for msg in messages where msg.role != .system {
            llmMessages.append(["role": msg.role.rawValue, "content": msg.content])
        }
        let userText = messages.last?.content

        streamTask = Task {
            isStreaming = true
            streamingResponse = ""
            streamingReasoning = ""
            defer { isStreaming = false }

            do {
                for try await event in provider.streamChat(messages: llmMessages, system: system) {
                    switch event {
                    case .token(let token):
                        streamingResponse += token
                    case .reasoning(let text):
                        streamingReasoning += text
                    }
                }
                let response = streamingResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                if !response.isEmpty {
                    messages.append(ChatMessage(role: .assistant, content: response,
                                                modelUsed: provider.modelIdentity))
                } else if !Task.isCancelled {
                    lastError = "The model returned an empty response."
                    lastFailedUserMessage = userText
                }
                streamingResponse = ""
                streamingReasoning = ""
                saveChat()
            } catch is CancellationError {
                if !streamingResponse.isEmpty {
                    messages.append(ChatMessage(role: .assistant, content: streamingResponse + " (interrupted)",
                                                modelUsed: provider.modelIdentity))
                    saveChat()
                }
                streamingResponse = ""
                streamingReasoning = ""
            } catch {
                if !streamingResponse.isEmpty {
                    messages.append(ChatMessage(role: .assistant, content: streamingResponse + " (interrupted)",
                                                modelUsed: provider.modelIdentity))
                }
                streamingResponse = ""
                streamingReasoning = ""
                lastError = error.localizedDescription
                lastFailedUserMessage = userText
            }
        }
    }

    // MARK: - Context building

    private func buildSystemPrompt(budget: Int) -> String {
        switch context {
        case .recording(let recording):
            if let url = recording.transcriptionURL,
               let transcript = try? String(contentsOf: url, encoding: .utf8) {
                return "You are a helpful assistant. Answer questions based on this transcript:\n\n\(transcript.prefix(max(1_000, budget - 500)))"
            }
            return "You are a helpful assistant. The user is asking about an audio recording that hasn't been transcribed yet."

        case .global:
            let manifest = buildManifest(budget: budget)
            return """
            You are a helpful assistant with access to audio recording transcripts. \
            Here is a summary of available recordings:

            \(manifest)

            Answer the user's questions based on this information. If you need more detail \
            from a specific recording, mention which one.
            """
        }
    }

    private func buildManifest(budget: Int) -> String {
        // Scale per-recording previews with the provider's budget.
        let previewWords = budget > 20_000 ? 1_000 : 200
        var manifest = ""
        for recording in store.recordings {
            manifest += "Recording: \(recording.displayName)\n"
            manifest += "  Date: \(recording.date.formatted())\n"
            manifest += "  Duration: \(recording.durationString)\n"
            if let summary = SummarizationService.loadSummary(for: recording) {
                manifest += "  Summary: \(summary.summary.prefix(previewWords * 5))\n"
            }
            if let url = recording.transcriptionURL,
               let content = try? String(contentsOf: url, encoding: .utf8) {
                let words = content.split(separator: " ").prefix(previewWords).joined(separator: " ")
                manifest += "  Transcript preview: \(words)\n"
            }
            manifest += "\n"
            if manifest.count > budget - 2_000 { break }
        }
        return manifest
    }

    // MARK: - Persistence

    private func loadChat() {
        guard let data = try? Data(contentsOf: chatFileURL),
              let history = try? JSONDecoder().decode(ChatHistory.self, from: data) else { return }
        messages = history.messages
    }

    private func saveChat() {
        let history = ChatHistory(messages: messages, recordingID: recordingForContext?.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(history) {
            try? data.write(to: chatFileURL)
        }
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(
                        message.role == .user
                            ? AppTheme.accent.opacity(0.15)
                            : Color(nsColor: .controlBackgroundColor)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(message.role == .user ? "You" : (message.modelUsed ?? "AI"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}
