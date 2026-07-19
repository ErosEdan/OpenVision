// OpenVision - DocumentChunkingTests.swift
// Pure text math behind the document store (RAG): chunking, cosine similarity, keyword bonus.

import XCTest
@testable import OpenVision

final class DocumentChunkingTests: XCTestCase {

    // MARK: - chunks()

    func testShortTextIsOneChunk() {
        let chunks = DocumentChunking.chunks("A short paragraph.")
        XCTAssertEqual(chunks, ["A short paragraph."])
    }

    func testEmptyTextYieldsNoChunks() {
        XCTAssertEqual(DocumentChunking.chunks(""), [])
        XCTAssertEqual(DocumentChunking.chunks("  \n\n  "), [])
    }

    func testParagraphsPackIntoTargetSizedChunks() {
        let paragraph = String(repeating: "Some sentence here. ", count: 20)  // ~400 chars
        let text = [paragraph, paragraph, paragraph].joined(separator: "\n\n") // ~1200 chars total
        let chunks = DocumentChunking.chunks(text, targetSize: 900)
        XCTAssertGreaterThan(chunks.count, 1, "1200 chars should not fit one 900-char chunk")
        for chunk in chunks {
            // Soft limit: a chunk may exceed target only by the overlap sentence.
            XCTAssertLessThan(chunk.count, 1100)
        }
    }

    func testOversizedParagraphSplitsOnSentences() {
        let big = String(repeating: "This is sentence number one of the manual. ", count: 40) // ~1700 chars, one paragraph
        let chunks = DocumentChunking.chunks(big, targetSize: 500)
        XCTAssertGreaterThan(chunks.count, 2)
        // No chunk should cut mid-sentence: each ends with a terminator.
        for chunk in chunks.dropLast() {
            XCTAssertTrue(chunk.hasSuffix("."), "chunk should end at a sentence boundary: …\(chunk.suffix(20))")
        }
    }

    func testAllTextIsPreserved() {
        let text = (1...30).map { "Fact number \($0) lives here." }.joined(separator: "\n\n")
        let chunks = DocumentChunking.chunks(text, targetSize: 200)
        let joined = chunks.joined(separator: " ")
        for i in 1...30 {
            XCTAssertTrue(joined.contains("Fact number \(i)"), "fact \(i) lost in chunking")
        }
    }

    // MARK: - cosineSimilarity()

    func testCosineIdenticalVectorsIsOne() {
        XCTAssertEqual(DocumentChunking.cosineSimilarity([1, 2, 3], [1, 2, 3]), 1.0, accuracy: 1e-9)
    }

    func testCosineOrthogonalVectorsIsZero() {
        XCTAssertEqual(DocumentChunking.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 1e-9)
    }

    func testCosineOppositeVectorsIsMinusOne() {
        XCTAssertEqual(DocumentChunking.cosineSimilarity([1, 1], [-1, -1]), -1.0, accuracy: 1e-9)
    }

    func testCosineMismatchedOrEmptyIsZero() {
        XCTAssertEqual(DocumentChunking.cosineSimilarity([1, 2], [1, 2, 3]), 0)
        XCTAssertEqual(DocumentChunking.cosineSimilarity([], []), 0)
        XCTAssertEqual(DocumentChunking.cosineSimilarity([0, 0], [1, 2]), 0)   // zero-norm guard
    }

    // MARK: - keywordBonus()

    func testKeywordBonusCountsMatchedTerms() {
        XCTAssertEqual(DocumentChunking.keywordBonus(query: "router error blinking",
                                                     text: "If the router shows a blinking light…"),
                       0.10, accuracy: 1e-9)   // "router" + "blinking" match; "error" doesn't
    }

    func testKeywordBonusIsCapped() {
        let text = "alpha bravo charlie delta echo foxtrot"
        XCTAssertEqual(DocumentChunking.keywordBonus(query: "alpha bravo charlie delta echo",
                                                     text: text),
                       0.15, accuracy: 1e-9)   // 5 matches would be 0.25 — capped at 0.15
    }

    func testKeywordBonusIgnoresShortWords() {
        // Terms of length ≤3 ("the", "a", "of") are noise and must not score.
        XCTAssertEqual(DocumentChunking.keywordBonus(query: "the of a is",
                                                     text: "the of a is everywhere"),
                       0.0, accuracy: 1e-9)
    }

    func testKeywordBonusCaseInsensitive() {
        XCTAssertEqual(DocumentChunking.keywordBonus(query: "ROUTER", text: "my router is fine"),
                       0.05, accuracy: 1e-9)
    }

    // MARK: - bestTitleMatch() (voice "open my …" → document)

    private let titles = ["TP-Link Router Manual", "Grandma's Lasagna Recipe", "Authorization Letter 2026"]

    func testTitleMatchFindsByKeyword() {
        XCTAssertEqual(DocumentChunking.bestTitleMatch(query: "router manual", titles: titles), 0)
        XCTAssertEqual(DocumentChunking.bestTitleMatch(query: "the lasagna recipe", titles: titles), 1)
        XCTAssertEqual(DocumentChunking.bestTitleMatch(query: "authorization letter", titles: titles), 2)
    }

    func testTitleMatchIsCaseInsensitive() {
        XCTAssertEqual(DocumentChunking.bestTitleMatch(query: "ROUTER", titles: titles), 0)
    }

    func testTitleMatchPartialTokens() {
        // Spoken words often partially match compound titles ("authorization" vs "Authorization Letter 2026").
        XCTAssertEqual(DocumentChunking.bestTitleMatch(query: "open the authorization", titles: titles), 2)
    }

    func testTitleMatchNoOverlapIsNil() {
        XCTAssertNil(DocumentChunking.bestTitleMatch(query: "tax return", titles: titles))
        XCTAssertNil(DocumentChunking.bestTitleMatch(query: "", titles: titles))
        XCTAssertNil(DocumentChunking.bestTitleMatch(query: "router", titles: []))
    }

    func testTitleMatchPrefersMoreOverlap() {
        let ambiguous = ["Router Setup Guide", "Router Manual TP-Link"]
        XCTAssertEqual(DocumentChunking.bestTitleMatch(query: "router manual", titles: ambiguous), 1)
    }

    // MARK: - relevantWindow() (keyword-centered excerpt capping)

    func testWindowKeepsKeywordSentenceBeyondPrefix() {
        // The asked-about sentence sits past the cap — a naive prefix would discard it.
        let boilerplate = String(repeating: "Header line with address details. ", count: 20) // ~680 chars
        let text = boilerplate + "I hereby authorize Mansi Kumari to collect the belongings."
        let window = DocumentChunking.relevantWindow(text: text, query: "is Mansi authorized", limit: 300)
        XCTAssertTrue(window.contains("authorize Mansi Kumari"), "keyword region must survive the cap")
        XCTAssertLessThan(window.count, 320)
    }

    func testWindowShortTextUnchanged() {
        XCTAssertEqual(DocumentChunking.relevantWindow(text: "Short text.", query: "anything", limit: 450),
                       "Short text.")
    }

    func testWindowNoKeywordFallsBackToHead() {
        let text = "First sentence here. " + String(repeating: "More filler content. ", count: 40)
        let window = DocumentChunking.relevantWindow(text: text, query: "zebra", limit: 100)
        XCTAssertTrue(window.hasPrefix("First sentence here."))
        XCTAssertLessThanOrEqual(window.count, 110)
    }

    func testWindowMarksTruncationWithEllipses() {
        let text = String(repeating: "Padding sentence. ", count: 30) + "The keyword target lives here."
            + String(repeating: " Trailing sentence.", count: 30)
        let window = DocumentChunking.relevantWindow(text: text, query: "keyword", limit: 200)
        XCTAssertTrue(window.contains("keyword target"))
        XCTAssertTrue(window.hasPrefix("…"))
        XCTAssertTrue(window.hasSuffix("…"))
    }
}
