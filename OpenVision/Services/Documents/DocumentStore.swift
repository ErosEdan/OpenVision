// OpenVision - DocumentStore.swift
// Local document store for grounded answers (RAG): import a PDF/text file, chunk it
// (DocumentChunking), embed each chunk with Apple's on-device NLEmbedding, and persist as JSON.
// At question time, `search` embeds the query and returns the best-matching excerpts, which the
// backends inject into the model's context via the `search_docs` native tool.
//
// Everything runs on-device (NLEmbedding is offline) — documents never leave the phone.
// Storage: Documents/RAGDocuments/<id>.json, one file per document, loaded once and cached.

import Foundation
import PDFKit
import NaturalLanguage

/// One imported document with its embedded chunks.
struct StoredDocument: Codable, Identifiable {
    let id: String
    let title: String
    /// "pdf", "text", "url", "photo" — how it was imported (drives UI icons; url/photo are Phase 2).
    let source: String
    let addedAt: Date
    let chunks: [StoredChunk]
}

struct StoredChunk: Codable {
    let text: String
    let embedding: [Double]
}

/// A search hit handed back to the tool layer.
struct DocumentHit {
    let documentTitle: String
    let text: String
    let score: Double
}

final class DocumentStore {
    static let shared = DocumentStore()

    private let queue = DispatchQueue(label: "com.openvision.document-store")
    private var cache: [StoredDocument]?
    /// Loaded once — NLEmbedding init reads a model from disk.
    private lazy var embedder = NLEmbedding.sentenceEmbedding(for: .english)

    private var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("RAGDocuments", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Import

    enum ImportError: LocalizedError {
        case unreadable, empty, embeddingUnavailable
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read that file"
            case .empty: return "No text found in the document"
            case .embeddingUnavailable: return "On-device embedding model unavailable"
            }
        }
    }

    /// Import a PDF or plain-text file. Blocking (extraction + embedding) — call from a
    /// background task. Returns the stored document.
    func importFile(at url: URL) throws -> StoredDocument {
        let isPDF = url.pathExtension.lowercased() == "pdf"
        let text: String
        if isPDF {
            guard let pdf = PDFDocument(url: url) else { throw ImportError.unreadable }
            text = (0..<pdf.pageCount)
                .compactMap { pdf.page(at: $0)?.string }
                .joined(separator: "\n\n")
        } else {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                throw ImportError.unreadable
            }
            text = raw
        }
        let title = url.deletingPathExtension().lastPathComponent
        return try importText(text, title: title, source: isPDF ? "pdf" : "text")
    }

    /// Import raw text (also the entry point for Phase 2's URL/photo importers).
    func importText(_ text: String, title: String, source: String) throws -> StoredDocument {
        let pieces = DocumentChunking.chunks(text)
        guard !pieces.isEmpty else { throw ImportError.empty }
        guard let embedder else { throw ImportError.embeddingUnavailable }

        let chunks: [StoredChunk] = pieces.map { piece in
            // NLEmbedding degrades on very long input — embed a bounded prefix, keep full text.
            let vector = embedder.vector(for: String(piece.prefix(1000))) ?? []
            return StoredChunk(text: piece, embedding: vector)
        }
        let doc = StoredDocument(id: UUID().uuidString, title: title, source: source,
                                 addedAt: Date(), chunks: chunks)
        try queue.sync {
            let data = try JSONEncoder().encode(doc)
            try data.write(to: directory.appendingPathComponent("\(doc.id).json"))
            if cache != nil { cache?.append(doc) }
        }
        NSLog("[Docs] Imported \"%@\" (%@): %d chunks", title, source, chunks.count)
        return doc
    }

    // MARK: - Query

    /// All stored documents (metadata order: newest first).
    func documents() -> [StoredDocument] {
        queue.sync { loadLocked().sorted { $0.addedAt > $1.addedAt } }
    }

    func remove(id: String) {
        queue.sync {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
            cache?.removeAll { $0.id == id }
        }
    }

    /// Top-k most relevant chunks for `query` — across all documents, or scoped to one
    /// (`documentId`, used by document-focus mode). Scoring: cosine + exact-keyword bonus.
    func search(_ query: String, k: Int = 3, documentId: String? = nil) -> [DocumentHit] {
        guard let embedder, let queryVector = embedder.vector(for: query) else { return [] }
        var docs = queue.sync { loadLocked() }
        if let documentId { docs = docs.filter { $0.id == documentId } }
        var hits: [DocumentHit] = []
        for doc in docs {
            for chunk in doc.chunks {
                let score = DocumentChunking.cosineSimilarity(queryVector, chunk.embedding)
                    + DocumentChunking.keywordBonus(query: query, text: chunk.text)
                hits.append(DocumentHit(documentTitle: doc.title, text: chunk.text, score: score))
            }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(k))
    }

    // MARK: - Private

    /// Must be called on `queue`.
    private func loadLocked() -> [StoredDocument] {
        if let cache { return cache }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        let docs = files.filter { $0.pathExtension == "json" }.compactMap { url -> StoredDocument? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(StoredDocument.self, from: data)
        }
        cache = docs
        return docs
    }
}
