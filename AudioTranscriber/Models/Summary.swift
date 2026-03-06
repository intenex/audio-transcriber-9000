import Foundation

struct RecordingSummary: Codable {
    let summary: String
    let actionItems: [String]
    let generatedName: String
    let generatedAt: Date
}
