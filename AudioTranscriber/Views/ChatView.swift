import SwiftUI

struct ChatView: View {
    let recording: Recording
    @Environment(LLMService.self) private var llmService
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var streamingResponse = ""
    @State private var isStreaming = false

    private var chatFileURL: URL {
        recording.fileURL.deletingPathExtension().appendingPathExtension("chat.json")
    }

    var body: some View {
        VStack(spacing: 0) {
            if !llmService.isAvailable {
                llmUnavailableView
            } else {
                chatContent
            }
        }
        .onAppear { loadChat() }
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages.filter { $0.role != .system }) { message in
                            ChatBubble(message: message)
                        }
                        if !streamingResponse.isEmpty {
                            ChatBubble(message: ChatMessage(role: .assistant, content: streamingResponse))
                                .id("streaming")
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

            // Input bar
            HStack(spacing: 8) {
                TextField("Ask about this recording...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit { sendMessage() }

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

    private var llmUnavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Chat requires mlx-lm")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Install mlx-lm in the transcriber conda environment to chat about recordings.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Text("conda run -n transcriber pip install mlx-lm")
                .font(.caption.monospaced())
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text("The model (~4GB) downloads automatically on first use.")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        inputText = ""

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)

        Task {
            isStreaming = true
            streamingResponse = ""

            // Build messages array with system context
            var llmMessages: [[String: String]] = []

            // System message with transcript context
            if let transcriptURL = recording.transcriptionURL,
               let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8) {
                llmMessages.append(["role": "system", "content": "You are a helpful assistant. Answer questions based on this transcript:\n\n\(transcript.prefix(6000))"])
            } else {
                llmMessages.append(["role": "system", "content": "You are a helpful assistant. The user is asking about an audio recording that hasn't been transcribed yet."])
            }

            // Add conversation history
            for msg in messages where msg.role != .system {
                llmMessages.append(["role": msg.role.rawValue, "content": msg.content])
            }

            do {
                for try await token in llmService.chat(messages: llmMessages) {
                    await MainActor.run { streamingResponse += token }
                }
                let assistantMessage = ChatMessage(role: .assistant, content: streamingResponse)
                await MainActor.run {
                    messages.append(assistantMessage)
                    streamingResponse = ""
                    isStreaming = false
                }
                saveChat()
            } catch {
                let errorMsg = ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)")
                await MainActor.run {
                    messages.append(errorMsg)
                    streamingResponse = ""
                    isStreaming = false
                }
            }
        }
    }

    private func loadChat() {
        guard let data = try? Data(contentsOf: chatFileURL),
              let history = try? JSONDecoder().decode(ChatHistory.self, from: data) else { return }
        messages = history.messages
    }

    private func saveChat() {
        let history = ChatHistory(messages: messages, recordingID: recording.id)
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

                Text(message.role == .user ? "You" : "AI")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}
