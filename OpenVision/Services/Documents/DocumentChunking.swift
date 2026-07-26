// OpenVision - DocumentChunking.swift
// Pure, unit-testable text math for the document store (RAG): splitting imported documents into
// retrievable chunks, and scoring chunks against a query (cosine similarity + keyword bonus).
//
// Chunking strategy: paragraph-first. Paragraphs are packed into chunks of roughly `targetSize`
// characters; an oversized paragraph is split on sentence boundaries (TextChunking.sentences).
// Each chunk carries the last sentence of the previous chunk as overlap, so a fact straddling a
// boundary is retrievable from either side.

import Foundation

enum DocumentChunking {

    /// Split document text into chunks of roughly `targetSize` characters (soft limit).
    static func chunks(_ text: String, targetSize: Int = 900) -> [String] {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return [] }

        // Break oversized paragraphs into sentence-bounded pieces first.
        var units: [String] = []
        for p in paragraphs {
            if p.count <= targetSize {
                units.append(p)
            } else {
                var piece = ""
                for sentence in TextChunking.sentences(p) {
                    if piece.count + sentence.count + 1 > targetSize, !piece.isEmpty {
                        units.append(piece)
                        piece = ""
                    }
                    piece += (piece.isEmpty ? "" : " ") + sentence
                }
                if !piece.isEmpty { units.append(piece) }
            }
        }

        // Pack units into chunks near the target size, carrying one sentence of overlap.
        var result: [String] = []
        var current = ""
        for unit in units {
            if current.count + unit.count + 2 > targetSize, !current.isEmpty {
                result.append(current)
                let overlap = TextChunking.sentences(current).last ?? ""
                current = overlap.count < targetSize / 3 ? overlap : ""
            }
            current += (current.isEmpty ? "" : "\n") + unit
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Cosine similarity of two equal-length vectors; 0 for mismatched/empty input.
    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / ((na * nb).squareRoot())
    }

    /// Bound an excerpt to ~`limit` chars, keeping the region around the query's keywords rather
    /// than blindly keeping the head. Naive prefix-capping silently discarded the exact sentence
    /// the user asked about whenever it sat past the cap (a letter's first chunk starts with
    /// header boilerplate; "I hereby authorize…" lives mid-chunk). Falls back to a
    /// sentence-bounded head when no keyword occurs in the text.
    static func relevantWindow(text: String, query: String, limit: Int = 450) -> String {
        guard text.count > limit else { return text }
        let terms = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }

        // Earliest occurrence of any query term (case-insensitive, searched on `text` itself so
        // indices stay valid).
        var earliest: Range<String.Index>?
        for term in terms {
            if let r = text.range(of: term, options: .caseInsensitive) {
                if earliest == nil || r.lowerBound < earliest!.lowerBound { earliest = r }
            }
        }

        guard let hit = earliest else {
            let head = String(text.prefix(limit))
            if let boundary = TextChunking.lastSentenceBoundary(in: head) {
                return String(head[..<boundary])
            }
            return head + "…"
        }

        // Window of `limit` chars with the hit about a third in — keeps the sentence before it
        // for context and room after it for the actual answer.
        let hitOffset = text.distance(from: text.startIndex, to: hit.lowerBound)
        let start = max(0, hitOffset - limit / 3)
        let end = min(text.count, start + limit)
        let startIdx = text.index(text.startIndex, offsetBy: start)
        let endIdx = text.index(text.startIndex, offsetBy: end)
        var window = String(text[startIdx..<endIdx])
        if start > 0 { window = "…" + window }
        if end < text.count { window += "…" }
        return window
    }

    /// Best-matching title for a spoken document name ("open my router manual" → "TP-Link Router
    /// Manual"). Token-overlap scoring: each query token (len > 2) found in a title scores 1;
    /// highest score wins; nil when nothing overlaps. Case-insensitive; ignores punctuation.
    static func bestTitleMatch(query: String, titles: [String]) -> Int? {
        func tokens(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        }
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return nil }
        var best: (index: Int, score: Int)?
        for (i, title) in titles.enumerated() {
            let titleTokens = Set(tokens(title))
            let score = queryTokens.filter { qt in
                titleTokens.contains { $0.contains(qt) || qt.contains($0) }
            }.count
            if score > 0, score > (best?.score ?? 0) { best = (i, score) }
        }
        return best?.index
    }

    /// Small additive bonus when query keywords literally appear in the chunk — sentence
    /// embeddings on long chunks are fuzzy, and exact matches (error codes, part names) are
    /// strong relevance signals they can miss. +0.05 per matched term, capped at +0.15.
    static func keywordBonus(query: String, text: String) -> Double {
        let lowerText = text.lowercased()
        let terms = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
        let matches = terms.filter { lowerText.contains($0) }.count
        return min(0.15, Double(matches) * 0.05)
    }
}
