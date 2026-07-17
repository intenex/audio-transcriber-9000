import Foundation

/// OpenAI `gpt-4o-transcribe-diarize` response (`response_format: diarized_json`).
/// Decoded defensively — unknown fields ignored, speaker optional.
struct DiarizedJSONResponse: Decodable {
    struct Segment: Decodable {
        let id: String?
        let start: Double
        let end: Double
        let text: String
        let speaker: String?
        let type: String?
    }

    let text: String?
    let duration: Double?
    let segments: [Segment]
}

/// OpenAI error envelope.
struct OpenAIErrorBody: Decodable {
    struct APIError: Decodable {
        let message: String?
        let type: String?
        let code: String?
    }
    let error: APIError?
}
