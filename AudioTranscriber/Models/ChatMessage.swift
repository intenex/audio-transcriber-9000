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

    init(id: UUID = UUID(), role: ChatRole, content: String, timestamp: Date = .now) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
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
