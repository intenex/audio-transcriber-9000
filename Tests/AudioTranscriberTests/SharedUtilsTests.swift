import XCTest
@testable import AudioTranscriber

final class SSEParserTests: XCTestCase {

    func testSimpleEvents() {
        var parser = SSEParser()
        let events = parser.consume("data: hello\n\ndata: world\n\n")
        XCTAssertEqual(events, ["hello", "world"])
    }

    func testEventSplitAcrossChunks() {
        var parser = SSEParser()
        var events = parser.consume("data: hel")
        XCTAssertEqual(events, [])
        events = parser.consume("lo\n")
        XCTAssertEqual(events, [])
        events = parser.consume("\n")
        XCTAssertEqual(events, ["hello"])
    }

    func testCRLFLineEndings() {
        var parser = SSEParser()
        let events = parser.consume("data: one\r\n\r\ndata: two\r\n\r\n")
        XCTAssertEqual(events, ["one", "two"])
    }

    func testMultiLineData() {
        var parser = SSEParser()
        let events = parser.consume("data: line1\ndata: line2\n\n")
        XCTAssertEqual(events, ["line1\nline2"])
    }

    func testCommentsAndOtherFieldsIgnored() {
        var parser = SSEParser()
        let events = parser.consume(": comment\nevent: message\nid: 3\ndata: payload\n\n")
        XCTAssertEqual(events, ["payload"])
    }

    func testDoneSentinelPassedThrough() {
        var parser = SSEParser()
        let events = parser.consume("data: [DONE]\n\n")
        XCTAssertEqual(events, ["[DONE]"])
    }

    func testNoSpaceAfterColon() {
        var parser = SSEParser()
        let events = parser.consume("data:{\"a\":1}\n\n")
        XCTAssertEqual(events, ["{\"a\":1}"])
    }

    func testFinishFlushesUnterminatedEvent() {
        var parser = SSEParser()
        _ = parser.consume("data: tail")
        XCTAssertEqual(parser.finish(), ["tail"])
    }
}

final class MultipartFormDataTests: XCTestCase {

    func testFraming() {
        var form = MultipartFormData(boundary: "BOUND")
        form.addField(name: "model", value: "test-model")
        form.addFile(name: "file", filename: "a.m4a", mimeType: "audio/mp4", data: Data([0x01, 0x02]))
        let body = String(decoding: form.encoded(), as: UTF8.self)

        XCTAssertTrue(body.contains("--BOUND\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ntest-model\r\n"))
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"file\"; filename=\"a.m4a\"\r\n"))
        XCTAssertTrue(body.contains("Content-Type: audio/mp4\r\n"))
        XCTAssertTrue(body.hasSuffix("--BOUND--\r\n"))
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=BOUND")
    }

    func testRepeatedFieldsForArrays() {
        var form = MultipartFormData(boundary: "B")
        form.addField(name: "known_speaker_names[]", value: "Ben")
        form.addField(name: "known_speaker_names[]", value: "Alice")
        let body = String(decoding: form.encoded(), as: UTF8.self)
        let count = body.components(separatedBy: "name=\"known_speaker_names[]\"").count - 1
        XCTAssertEqual(count, 2)
    }
}

final class KeychainStoreTests: XCTestCase {
    // Use a unique service so tests never touch the real app's secrets.
    private let store = KeychainStore(service: "com.audiotranscriber.tests.\(UUID().uuidString)")

    override func tearDown() {
        for key in SecretKey.allCases { store.delete(key) }
        super.tearDown()
    }

    func testSetGetRoundTrip() {
        store.set("sk-test-123", for: .openAI)
        XCTAssertEqual(store.get(.openAI), "sk-test-123")
    }

    func testOverwrite() {
        store.set("first", for: .miniMax)
        store.set("second", for: .miniMax)
        XCTAssertEqual(store.get(.miniMax), "second")
    }

    func testDelete() {
        store.set("value", for: .custom)
        store.delete(.custom)
        XCTAssertNil(store.get(.custom))
    }

    /// Regression: `set("")` used to DELETE the stored key. Combined with the
    /// SecureField transiently emptying during a paste, that destroyed keys
    /// the moment users tried to save them. Empty/whitespace is now a no-op —
    /// removal happens only via explicit delete().
    func testEmptySetKeepsExistingValue() {
        store.set("value", for: .assemblyAI)
        store.set("", for: .assemblyAI)
        store.set("  \n", for: .assemblyAI)
        XCTAssertEqual(store.get(.assemblyAI), "value")
        XCTAssertTrue(store.has(.assemblyAI))
    }

    func testSetTrimsWhitespace() {
        store.set("  sk-padded \n", for: .custom)
        XCTAssertEqual(store.get(.custom), "sk-padded")
    }

    func testSetReportsSuccess() {
        XCTAssertTrue(store.set("v1", for: .miniMax))
        XCTAssertTrue(store.set("v2", for: .miniMax))   // update path
        XCTAssertTrue(store.set("", for: .miniMax))     // no-op path
        XCTAssertEqual(store.get(.miniMax), "v2")
    }

    func testHas() {
        XCTAssertFalse(store.has(.openAI))
        store.set("k", for: .openAI)
        XCTAssertTrue(store.has(.openAI))
    }

    func testInMemoryStore() {
        let mem = InMemorySecretsStore()
        mem.set("abc", for: .openAI)
        XCTAssertEqual(mem.get(.openAI), "abc")
        mem.delete(.openAI)
        XCTAssertNil(mem.get(.openAI))
    }
}
