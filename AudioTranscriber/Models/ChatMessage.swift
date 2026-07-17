import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: ChatRole
    let content: String
    let timestamp: Date
    /// Model that produced this message (assistant messages only).
    /// Optional so chat histories from before this field decode fine.
    let modelUsed: String?

    init(id: UUID = UUID(), role: ChatRole, content: String, timestamp: Date = .now,
         modelUsed: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.modelUsed = modelUsed
    }
}

struct ChatHistory: Codable {
    var messages: [ChatMessage]
    let recordingID: UUID?

    init(messages: [ChatMessage] = [], recordingID: UUID? = nil) {
        self.messages = messages
        self.recordingID = recordingID
    }
}
