import Foundation

struct RecordingSummary: Codable {
    let summary: String
    let actionItems: [String]
    let generatedName: String
    let generatedAt: Date

    // v2 fields — optional so pre-existing .summary.json sidecars still decode.
    var keyPoints: [String]? = nil
    var decisions: [String]? = nil
    var topics: [String]? = nil
    var modelUsed: String? = nil
}
