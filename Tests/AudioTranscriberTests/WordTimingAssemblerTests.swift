import XCTest
@testable import AudioTranscriber

final class WordTimingAssemblerTests: XCTestCase {

    func testNormalizedTokensWithLeadingSpaces() {
        // FluidAudio-normalized: "▁" already replaced with space
        let words = WordTimingAssembler.assemble(tokens: [
            (" Hello", 0.0, 0.2),
            (",", 0.2, 0.25),
            (" wor", 0.3, 0.4),
            ("ld", 0.4, 0.5),
        ])
        XCTAssertEqual(words.map(\.word), ["Hello,", "world"])
        XCTAssertEqual(words[0].start, 0.0)
        XCTAssertEqual(words[0].end, 0.25)
        XCTAssertEqual(words[1].start, 0.3)
        XCTAssertEqual(words[1].end, 0.5)
    }

    func testRawSentencePieceTokens() {
        let words = WordTimingAssembler.assemble(tokens: [
            ("▁Hi", 0.0, 0.1),
            ("▁there", 0.2, 0.4),
        ])
        XCTAssertEqual(words.map(\.word), ["Hi", "there"])
    }

    func testSubwordContinuation() {
        let words = WordTimingAssembler.assemble(tokens: [
            (" trans", 1.0, 1.2),
            ("crip", 1.2, 1.3),
            ("tion", 1.3, 1.5),
        ])
        XCTAssertEqual(words.map(\.word), ["transcription"])
        XCTAssertEqual(words[0].start, 1.0)
        XCTAssertEqual(words[0].end, 1.5)
    }

    func testEmptyInput() {
        XCTAssertTrue(WordTimingAssembler.assemble(tokens: []).isEmpty)
    }

    func testWhitespaceOnlyTokensDropped() {
        let words = WordTimingAssembler.assemble(tokens: [(" ", 0, 0.1), ("  ", 0.1, 0.2)])
        XCTAssertTrue(words.isEmpty)
    }
}
