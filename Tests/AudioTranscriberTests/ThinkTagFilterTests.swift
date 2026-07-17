import XCTest
@testable import AudioTranscriber

final class ThinkTagFilterTests: XCTestCase {

    func testSingleChunkWithThinkBlock() {
        var filter = ThinkTagFilter()
        let result = filter.process("<think>\nreasoning here\n</think>\n\nOK")
        XCTAssertEqual(result.content.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
        XCTAssertTrue(result.reasoning.contains("reasoning here"))
    }

    func testTagSplitAcrossChunks() {
        var filter = ThinkTagFilter()
        var content = ""
        var reasoning = ""
        for chunk in ["<th", "ink>secret", " thoughts</thi", "nk>visible"] {
            let r = filter.process(chunk)
            content += r.content
            reasoning += r.reasoning
        }
        let tail = filter.flush()
        content += tail.content
        XCTAssertEqual(content, "visible")
        XCTAssertEqual(reasoning, "secret thoughts")
    }

    func testNoThinkBlockPassesThrough() {
        var filter = ThinkTagFilter()
        let r = filter.process("Hello world")
        let tail = filter.flush()
        XCTAssertEqual(r.content + tail.content, "Hello world")
        XCTAssertTrue(r.reasoning.isEmpty)
    }

    func testAngleBracketWithoutTagNotSwallowed() {
        var filter = ThinkTagFilter()
        let r1 = filter.process("a < b and x <thing> y")
        let tail = filter.flush()
        XCTAssertEqual(r1.content + tail.content, "a < b and x <thing> y")
    }

    func testUnclosedThinkFlushedAsReasoning() {
        var filter = ThinkTagFilter()
        let r = filter.process("<think>never closed")
        let tail = filter.flush()
        XCTAssertEqual(r.content + tail.content, "")
        XCTAssertEqual(r.reasoning + tail.reasoning, "never closed")
    }

    func testStrippingHelperForNonStreamingPaths() {
        let raw = "<think>\nThe user wants JSON.\n</think>\n\n{\"summary\": \"hi\"}"
        XCTAssertEqual(raw.strippingThinkBlocks(), "{\"summary\": \"hi\"}")
    }
}

final class SummaryParsingRobustnessTests: XCTestCase {

    func testParsesJSONWrappedInThinkBlockAndProse() async throws {
        // Feed via a mocked provider so the full summarize path runs.
        let secrets = InMemorySecretsStore([.openAI: "sk-test"])
        let provider = OpenAICompatibleChatProvider(
            id: .openAI, displayName: "Test",
            baseURL: { URL(string: "https://api.test.example/v1") },
            model: { "test" }, secretKey: .openAI, secrets: secrets,
            session: MockURLProtocol.makeSession())

        let json = #"{\"summary\": \"A brief call.\", \"actionItems\": [], \"generatedName\": \"Test Call\", \"keyPoints\": [\"one\"], \"decisions\": [], \"topics\": [\"testing\"]}"#
        MockURLProtocol.requestHandler = { request in
            let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"<think>pondering</think>Here you go: \(json)\"}}]}\n\ndata: [DONE]\n\n"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let summary = try await SummarizationService.summarize(transcript: "Hello.", provider: provider)
        XCTAssertEqual(summary.generatedName, "Test Call")
        XCTAssertEqual(summary.keyPoints, ["one"])
        XCTAssertEqual(summary.modelUsed, "test")
    }
}
