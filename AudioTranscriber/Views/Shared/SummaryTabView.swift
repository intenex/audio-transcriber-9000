import SwiftUI

/// The Summary tab, shared by both platforms: rendered summary with topics /
/// key points / decisions / action items, generate-and-retry states, and the
/// suggested-name affordance.
struct SummaryTabView: View {
    let recording: Recording
    let markdownContent: String?
    @Binding var loadedSummary: RecordingSummary?
    @Binding var isRegenerating: Bool
    @Binding var summaryError: String?

    @Environment(RecordingStore.self) private var store
    @Environment(ChatService.self) private var chatService
    @Environment(TranscriptionService.self) private var transcriptionService

    var body: some View {
        if let summary = loadedSummary {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let topics = summary.topics, !topics.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(topics, id: \.self) { topic in
                                Text(topic)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(AppTheme.accent.opacity(0.1), in: Capsule())
                                    .foregroundStyle(AppTheme.accent)
                            }
                            Spacer()
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Summary", icon: "doc.text")
                        Text(attributedMarkdown(summary.summary))
                            .textSelection(.enabled)
                            .lineSpacing(3)
                    }

                    if let keyPoints = summary.keyPoints, !keyPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader("Key Points", icon: "list.bullet")
                            ForEach(keyPoints, id: \.self) { point in
                                bulletRow(icon: "smallcircle.filled.circle", tint: AppTheme.accent, text: point)
                            }
                        }
                    }

                    if let decisions = summary.decisions, !decisions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader("Decisions", icon: "checkmark.seal")
                            ForEach(decisions, id: \.self) { decision in
                                bulletRow(icon: "checkmark.seal.fill", tint: AppTheme.success, text: decision)
                            }
                        }
                    }

                    if !summary.actionItems.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader("Action Items", icon: "checklist")
                            ForEach(summary.actionItems, id: \.self) { item in
                                bulletRow(icon: "circle", tint: AppTheme.warning, text: item)
                            }
                        }
                    }

                    Divider()

                    HStack {
                        Text("Suggested name:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(summary.generatedName)
                            .font(.caption.weight(.medium))
                        if recording.name == nil {
                            Button("Use") {
                                store.update(recording.id) { $0.name = summary.generatedName }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }

                    HStack(spacing: 12) {
                        if chatService.isActiveProviderReady {
                            Button(action: { Task { await regenerate() } }) {
                                Label("Regenerate Summary", systemImage: "arrow.counterclockwise")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isRegenerating)
                        }
                        Text("Generated \(summary.generatedAt.formatted())\(summary.modelUsed.map { " · \($0)" } ?? "")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if isRegenerating {
            VStack(spacing: 12) {
                ProgressView()
                Text("Summarizing with \(chatService.activeProvider.modelIdentity)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Long recordings can take a few minutes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else if chatService.isActiveProviderReady {
            VStack(spacing: 16) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No summary yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let summaryError {
                    VStack(spacing: 6) {
                        Label(summaryError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.warning)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                            .textSelection(.enabled)
                    }
                }
                Button(action: { Task { await regenerate() } }) {
                    Label(summaryError == nil ? "Generate Summary" : "Try Again", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                Text("Using \(chatService.activeProvider.modelIdentity)")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Summarization needs an AI provider")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Add a MiniMax or OpenAI API key (or a custom endpoint) in Settings → AI Chat.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.title3.weight(.semibold))
            .labelStyle(.titleAndIcon)
    }

    private func bulletRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .padding(.top, 3)
            Text(attributedMarkdown(text))
                .textSelection(.enabled)
        }
    }

    private func regenerate() async {
        guard let content = markdownContent else { return }
        isRegenerating = true
        summaryError = nil
        defer { isRegenerating = false }

        do {
            let summary = try await SummarizationService.summarize(
                transcript: content,
                provider: chatService.activeProvider,
                namingContext: transcriptionService.namingContext(for: recording))
            SummarizationService.saveSummary(summary, for: recording)
            loadedSummary = summary

            if recording.name == nil {
                let generatedName = summary.generatedName
                store.update(recording.id) { $0.name = generatedName }
            }
        } catch {
            summaryError = error.localizedDescription
        }
    }
}
