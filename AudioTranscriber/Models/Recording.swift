import Foundation

enum TranscriptionStatus: String, Codable {
    case pending
    case processing
    case done
    case failed
}

struct Recording: Identifiable, Codable {
    let id: UUID
    let fileURL: URL
    let date: Date
    var duration: TimeInterval
    var transcriptionURL: URL?
    var status: TranscriptionStatus
    var name: String?

    init(fileURL: URL, date: Date = .now, duration: TimeInterval = 0) {
        self.id = UUID()
        self.fileURL = fileURL
        self.date = date
        self.duration = duration
        self.transcriptionURL = nil
        self.status = .pending
        self.name = nil
    }

    var displayName: String {
        name ?? formattedDate
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var durationString: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
