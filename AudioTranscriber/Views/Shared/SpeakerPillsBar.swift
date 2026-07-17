import SwiftUI

/// The speaker rename pills above the transcript, with the rename popover and
/// the "Remember this voice" enrollment toggle. Shared by both platforms
/// (.popover degrades to a sheet on iPhone).
struct SpeakerPillsBar: View {
    let speakers: [(id: String, num: Int)]
    @Binding var speakerNames: [String: String]
    @Binding var editingSpeakerID: String?
    @Binding var editingSpeakerName: String
    @Binding var rememberVoice: Bool
    let isEnrolling: Bool
    let onSave: (String) -> Void
    let onReset: (String) -> Void

    /// First-appearance speaker order for a segment list.
    static func uniqueSpeakers(in segs: [TranscriptionSegment]) -> [(id: String, num: Int)] {
        var order: [(id: String, num: Int)] = []
        var seen: Set<String> = []
        for seg in segs {
            if !seen.contains(seg.speaker) {
                seen.insert(seg.speaker)
                order.append((id: seg.speaker, num: order.count + 1))
            }
        }
        return order
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Speakers:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(speakers, id: \.id) { speaker in
                let displayName = speakerNames[speaker.id] ?? "Speaker \(speaker.num)"
                Button(action: {
                    editingSpeakerID = speaker.id
                    editingSpeakerName = speakerNames[speaker.id] ?? ""
                }) {
                    HStack(spacing: 4) {
                        Text(displayName)
                            .font(.caption.weight(.medium))
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.accent.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(
                    get: { editingSpeakerID == speaker.id },
                    set: { if !$0 { editingSpeakerID = nil } }
                )) {
                    VStack(spacing: 8) {
                        Text("Rename Speaker \(speaker.num)")
                            .font(.headline)
                        TextField("Name", text: $editingSpeakerName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onSubmit {
                                onSave(speaker.id)
                            }
                        Toggle("Remember this voice", isOn: $rememberVoice)
                            .font(.caption)
                            .help("Save a voice sample so this person is recognized automatically in future transcripts")
                        if isEnrolling {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.5)
                                Text("Saving voice sample…")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        HStack {
                            if speakerNames[speaker.id] != nil {
                                Button("Reset") {
                                    onReset(speaker.id)
                                }
                                .buttonStyle(.bordered)
                            }
                            Spacer()
                            Button("Cancel") { editingSpeakerID = nil }
                                .buttonStyle(.bordered)
                            Button("Save") {
                                onSave(speaker.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.accent)
                        }
                    }
                    .padding()
                    .frame(width: 260)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
