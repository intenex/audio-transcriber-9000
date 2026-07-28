import SwiftUI

/// Picks recordings and the order they play in, then combines them into one.
/// Order is the whole point — a call that got cut in two has a first half and
/// a second half — so the list is explicitly numbered and reorderable by
/// buttons as well as by dragging.
struct CombineRecordingsSheet: View {
    /// Recordings the sheet opens with (the row the user came from).
    let initialSelection: [UUID]

    @Environment(RecordingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var orderedIDs: [UUID] = []
    @State private var name = ""
    @State private var deleteOriginals = false
    @State private var isCombining = false

    private var parts: [Recording] {
        orderedIDs.compactMap { id in store.recordings.first { $0.id == id } }
    }

    private var candidates: [Recording] {
        store.recordings.filter { !orderedIDs.contains($0.id) }
    }

    private var totalDuration: TimeInterval {
        parts.reduce(0) { $0 + $1.duration }
    }

    private var totalBytes: Int64 {
        parts.reduce(0) { $0 + ($1.fileSizeBytes ?? 0) }
    }

    private var canCombine: Bool { parts.count >= 2 && !isCombining }

    var body: some View {
        content
            .onAppear {
                if orderedIDs.isEmpty { orderedIDs = initialSelection }
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Combine Recordings")
                    .font(.headline)
                Text("They are joined in the order below, top first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            partsList
            addMenu
            options
            Divider()
            HStack {
                resultLabel
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action: combine) {
                    if isCombining {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Combining…")
                        }
                    } else {
                        Text("Combine")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(!canCombine)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 460)
        #else
        NavigationStack {
            Form {
                Section {
                    partsRows
                } header: {
                    Text("Order — top plays first")
                } footer: {
                    resultLabel
                }
                Section {
                    addMenu
                }
                Section {
                    options
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Combine Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCombining {
                        ProgressView()
                    } else {
                        Button("Combine", action: combine).disabled(!canCombine)
                    }
                }
            }
        }
        #endif
    }

    // MARK: - Pieces

    private var partsList: some View {
        List {
            partsRows
        }
        #if os(macOS)
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minHeight: 160)
        #endif
    }

    @ViewBuilder
    private var partsRows: some View {
        if parts.isEmpty {
            Text("No recordings picked yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(parts.enumerated()), id: \.element.id) { index, recording in
                partRow(index: index, recording: recording)
            }
            .onMove { source, destination in
                orderedIDs.move(fromOffsets: source, toOffset: destination)
            }
        }
    }

    private func partRow(index: Int, recording: Recording) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(recording.formattedDate) · \(recording.durationString)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                move(from: index, to: index - 1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move earlier")

            Button {
                move(from: index, to: index + 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == parts.count - 1)
            .help("Move later")

            Button {
                orderedIDs.removeAll { $0 == recording.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove from the combination")
        }
        .padding(.vertical, 2)
    }

    private var addMenu: some View {
        Menu {
            if candidates.isEmpty {
                Text("Everything is already in the list")
            } else {
                ForEach(candidates) { recording in
                    Button {
                        orderedIDs.append(recording.id)
                    } label: {
                        Text("\(recording.displayName) — \(recording.durationString)")
                    }
                }
            }
        } label: {
            Label("Add Recording", systemImage: "plus.circle")
        }
        .disabled(candidates.isEmpty || isCombining)
    }

    @ViewBuilder
    private var options: some View {
        TextField("Name (optional)", text: $name)
            #if os(macOS)
            .textFieldStyle(.roundedBorder)
            #endif
        Toggle("Delete the original recordings afterwards", isOn: $deleteOriginals)
            .disabled(isCombining)
        Text(deleteOriginals
             ? "The originals and their transcripts are removed once the combined file is written and verified."
             : "The originals are kept. The combined recording starts untranscribed — transcribe it to get one transcript for the whole conversation.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var resultLabel: some View {
        Group {
            if parts.count >= 2 {
                Text("Result: \(RecordingMerger.timeLabel(totalDuration))"
                     + (totalBytes > 0
                        ? " · ~\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
                        : ""))
            } else {
                Text("Pick at least two recordings.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func move(from index: Int, to target: Int) {
        guard orderedIDs.indices.contains(index), orderedIDs.indices.contains(target) else { return }
        let id = orderedIDs.remove(at: index)
        orderedIDs.insert(id, at: target)
    }

    private func combine() {
        guard canCombine else { return }
        let selected = parts
        isCombining = true
        Task {
            let result = await store.combine(selected, name: name, deleteOriginals: deleteOriginals)
            isCombining = false
            if result != nil { dismiss() }
        }
    }
}
