import SwiftUI

struct GlobalChatView: View {
    @Environment(LLMService.self) private var llmService
    @Environment(AudioRecorder.self) private var audioRecorder
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var streamingResponse = ""
    @State private var isStreaming = false

    private var chatFileURL: URL {
        audioRecorder.storageDirectory.appendingPathComponent(".global-chat.json")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
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
                    Text("\(audioRecorder.recordings.count) recordings available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

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

            Divider()

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
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Ask about your recordings...", text: $inputText, axis: .vertical)
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
            Text("Global Chat requires mlx-lm")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Install mlx-lm in the transcriber conda environment to chat across all recordings.")
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

            // Build manifest of all recordings
            let manifest = buildManifest()

            var llmMessages: [[String: String]] = [
                ["role": "system", "content": """
                You are a helpful assistant with access to audio recording transcripts. \
                Here is a summary of available recordings:

                \(manifest)

                Answer the user's questions based on this information. If you need more detail \
                from a specific recording, mention which one.
                """]
            ]

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

    private func buildManifest() -> String {
        var manifest = ""
        for recording in audioRecorder.recordings {
            manifest += "Recording: \(recording.displayName)\n"
            manifest += "  Date: \(recording.date.formatted())\n"
            manifest += "  Duration: \(recording.durationString)\n"

            // Load summary if available
            if let summary = SummarizationService.loadSummary(for: recording) {
                manifest += "  Summary: \(summary.summary.prefix(200))\n"
            }

            // Load first 200 words of transcript
            if let url = recording.transcriptionURL,
               let content = try? String(contentsOf: url, encoding: .utf8) {
                let words = content.split(separator: " ").prefix(200).joined(separator: " ")
                manifest += "  Transcript preview: \(words)\n"
            }
            manifest += "\n"
        }
        return manifest
    }

    private func loadChat() {
        guard let data = try? Data(contentsOf: chatFileURL),
              let history = try? JSONDecoder().decode(ChatHistory.self, from: data) else { return }
        messages = history.messages
    }

    private func saveChat() {
        let history = ChatHistory(messages: messages, recordingID: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(history) {
            try? data.write(to: chatFileURL)
        }
    }
}
