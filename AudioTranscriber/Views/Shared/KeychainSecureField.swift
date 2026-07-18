import SwiftUI

// MARK: - Keychain-backed secure field

struct KeychainSecureField: View {
    let label: String
    let key: SecretKey
    var prompt: String = "Paste your API key"

    @State private var value = ""
    @State private var isSaved = false
    @State private var saveFailed = false
    @State private var isRevealed = false
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(prompt, text: $value)
                } else {
                    SecureField(prompt, text: $value)
                }
            }
            .textContentType(.password)
            .autocorrectionDisabled()
            .focused($focused)
            .onSubmit { commit() }

            // Trailing icons are always present, toggled via opacity: inserting
            // or removing views here restructures the container hosting the
            // active field editor, which reverts an in-progress paste — the
            // exact mechanism that made keys "not save" (and then get deleted).
            Image(systemName: saveFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(saveFailed ? AppTheme.warning : AppTheme.success)
                .opacity(saveFailed || (isSaved && !value.isEmpty) ? 1 : 0)
                .help(saveFailed ? "Couldn't save to Keychain" : "Saved in Keychain")
            Button(action: { isRevealed.toggle() }) {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(value.isEmpty ? 0 : 1)
            .disabled(value.isEmpty)
            .help(isRevealed ? "Hide key" : "Show key")
            Button(action: {
                saveTask?.cancel()
                value = ""
                KeychainStore.shared.delete(key)
                isSaved = false
                saveFailed = false
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(value.isEmpty ? 0 : 1)
            .disabled(value.isEmpty)
            .help("Remove key")
        }
        .onAppear {
            value = KeychainStore.shared.get(key) ?? ""
            isSaved = !value.isEmpty
        }
        // Debounced save — pasting persists without Enter, but no state is
        // mutated synchronously inside the change handler (that re-render
        // mid-edit is what broke saving before).
        .onChange(of: value) { _, newValue in
            saveTask?.cancel()
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                commit()
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        saveTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ok = KeychainStore.shared.set(trimmed, for: key)
        isSaved = ok
        saveFailed = !ok
    }
}
