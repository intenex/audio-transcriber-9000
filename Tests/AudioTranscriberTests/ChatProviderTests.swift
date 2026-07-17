import XCTest
@testable import AudioTranscriber

final class ChatProviderTests: XCTestCase {

    private func makeProvider(secrets: InMemorySecretsStore,
                              baseURL: String = "https://api.test.example/v1",
                              model: String = "test-model") -> OpenAICompatibleChatProvider {
        OpenAICompatibleChatProvider(
            id: .openAI, displayName: "Test",
            baseURL: { URL(string: baseURL) },
            model: { model },
            secretKey: .openAI,
            secrets: secrets,
            session: MockURLProtocol.makeSession())
    }

    private func sse(_ payloads: [String]) -> Data {
        Data((payloads.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n").utf8)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
    }

    func testTokenStreaming() async throws {
        let secrets = InMemorySecretsStore([.openAI: "sk-test"])
        let provider = makeProvider(secrets: secrets)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, "test-model")
            XCTAssertEqual(body?["stream"] as? Bool, true)

            let chunks = [
                #"{"choices":[{"delta":{"role":"assistant","content":"Hel"}}]}"#,
                #"{"choices":[{"delta":{"content":"lo"}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            ]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (response, self.sse(chunks))
        }

        var tokens: [String] = []
        for try await event in provider.streamChat(messages: [["role": "user", "content": "hi"]], system: nil) {
            if case .token(let t) = event { tokens.append(t) }
        }
        XCTAssertEqual(tokens.joined(), "Hello")
    }

    func testSystemPromptPrepended() async throws {
        let secrets = InMemorySecretsStore([.openAI: "sk-test"])
        let provider = makeProvider(secrets: secrets)

        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let messages = body?["messages"] as? [[String: String]]
            XCTAssertEqual(messages?.first?["role"], "system")
            XCTAssertEqual(messages?.first?["content"], "be brief")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, self.sse([#"{"choices":[{"delta":{"content":"ok"}}]}"#]))
        }

        _ = try await provider.generate(messages: [["role": "user", "content": "hi"]], system: "be brief")
    }

    func testMiniMaxReasoningContent() async throws {
        let secrets = InMemorySecretsStore([.openAI: "sk-test"])
        let provider = makeProvider(secrets: secrets)

        MockURLProtocol.requestHandler = { request in
            let chunks = [
                #"{"choices":[{"delta":{"reasoning_content":"thinking..."}}]}"#,
                #"{"choices":[{"delta":{"content":"Answer"}}]}"#,
            ]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, self.sse(chunks))
        }

        var reasoning: [String] = []
        var tokens: [String] = []
        for try await event in provider.streamChat(messages: [["role": "user", "content": "q"]], system: nil) {
            switch event {
            case .reasoning(let r): reasoning.append(r)
            case .token(let t): tokens.append(t)
            }
        }
        XCTAssertEqual(reasoning, ["thinking..."])
        XCTAssertEqual(tokens, ["Answer"])
    }

    func testMiniMaxBaseRespErrorWithHTTP200() async {
        let secrets = InMemorySecretsStore([.openAI: "sk-test"])
        let provider = makeProvider(secrets: secrets)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, self.sse([#"{"base_resp":{"status_code":1004,"status_msg":"invalid api key"}}"#]))
        }

        do {
            _ = try await provider.generate(messages: [["role": "user", "content": "q"]])
            XCTFail("expected error")
        } catch let error as ChatProviderError {
            if case .providerError(let msg) = error {
                XCTAssertTrue(msg.contains("invalid api key"))
            } else {
                XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testUnauthorized() async {
        let secrets = InMemorySecretsStore([.openAI: "sk-bad"])
        let provider = makeProvider(secrets: secrets)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":{"message":"bad key"}}"#.utf8))
        }

        do {
            _ = try await provider.generate(messages: [["role": "user", "content": "q"]])
            XCTFail("expected error")
        } catch let error as ChatProviderError {
            guard case .unauthorized = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testMissingKeyFailsFast() async {
        let provider = makeProvider(secrets: InMemorySecretsStore())
        XCTAssertFalse(provider.isConfigured)
        do {
            _ = try await provider.generate(messages: [["role": "user", "content": "q"]])
            XCTFail("expected error")
        } catch let error as ChatProviderError {
            guard case .missingAPIKey = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testUndecodableChunksSkipped() async throws {
        let secrets = InMemorySecretsStore([.openAI: "sk-test"])
        let provider = makeProvider(secrets: secrets)

        MockURLProtocol.requestHandler = { request in
            let body = "data: not-json\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        let result = try await provider.generate(messages: [["role": "user", "content": "q"]])
        XCTAssertEqual(result, "ok")
    }
}

@MainActor
final class ChatServiceSelectionTests: XCTestCase {

    private func makeService(secrets: InMemorySecretsStore) -> ChatService {
        let defaults = UserDefaults(suiteName: "ChatServiceTests-\(UUID().uuidString)")!
        return ChatService(secrets: secrets, defaults: defaults)
    }

    func testAutoDefaultPrefersMiniMaxWhenKeyed() {
        let service = makeService(secrets: InMemorySecretsStore([.miniMax: "mk", .openAI: "ok"]))
        XCTAssertEqual(service.activeProvider.id, .miniMax)
    }

    func testAutoDefaultFallsBackToOpenAI() {
        let service = makeService(secrets: InMemorySecretsStore([.openAI: "ok"]))
        XCTAssertEqual(service.activeProvider.id, .openAI)
    }

    func testAutoDefaultFallsBackToLocal() {
        let service = makeService(secrets: InMemorySecretsStore())
        XCTAssertEqual(service.activeProvider.id, .localMLX)
    }

    func testExplicitSelectionWins() {
        let service = makeService(secrets: InMemorySecretsStore([.miniMax: "mk"]))
        service.selectedProviderID = .localMLX
        XCTAssertEqual(service.activeProvider.id, .localMLX)
    }
}
