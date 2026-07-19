// OpenVision - DocumentFocus.swift
// "Document focus" mode: the user activates ONE document ("Vision, open my router manual") and,
// while it's active, every request auto-retrieves that document's most relevant excerpts into the
// model's context — retrieval becomes deterministic instead of relying on the model's judgment to
// call search_docs (which small local models get wrong). Off = normal phrasing-based routing.
//
// Focus is deliberately ephemeral: in-memory only (gone on app restart) and auto-released after
// 30 idle minutes — a forgotten mode silently steering answers days later would be worse than no
// mode at all.

import Foundation

@MainActor
final class DocumentFocus: ObservableObject {
    static let shared = DocumentFocus()

    @Published private(set) var activeDocument: StoredDocument?

    private var idleTimer: Timer?
    private let idleTimeout: TimeInterval = 30 * 60

    private init() {}

    // MARK: - Activation

    func activate(_ doc: StoredDocument) {
        activeDocument = doc
        touch()
        NSLog("[DocFocus] Focused on \"%@\"", doc.title)
    }

    func deactivate() {
        if let doc = activeDocument { NSLog("[DocFocus] Released \"%@\"", doc.title) }
        activeDocument = nil
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// Reset the idle clock — called on every use so an active working session never expires.
    private func touch() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { _ in
            Task { @MainActor in
                NSLog("[DocFocus] Idle timeout — releasing focus")
                DocumentFocus.shared.deactivate()
            }
        }
    }

    // MARK: - Context injection

    /// Context block for the current request while a document is focused, or nil when focus is
    /// off. Backends insert this into the prompt/messages for EVERY request during focus — the
    /// model always sees the excerpts and judges relevance itself, rather than deciding whether
    /// to search.
    func contextForQuery(_ query: String) -> String? {
        guard let doc = activeDocument else { return nil }
        touch()

        // Short documents (a letter, a recipe) are injected WHOLE — retrieval over 2-3 chunks
        // only risks capping away the one sentence that matters, for no context savings.
        let totalChars = doc.chunks.reduce(0) { $0 + $1.text.count }
        let excerpts: String
        if totalChars <= 2500 {
            excerpts = doc.chunks.map(\.text).joined(separator: "\n")
        } else {
            // Larger docs: retrieve top chunks, bounded per-excerpt (small on-device context
            // windows — Apple: 4096 tokens) but windowed AROUND the query's keywords so the
            // sentence being asked about survives the cap.
            let hits = DocumentStore.shared.search(query, k: 3, documentId: doc.id)
            excerpts = hits.isEmpty
                ? "(no section of the document matched this request)"
                : hits.map { DocumentChunking.relevantWindow(text: $0.text, query: query, limit: 450) }
                    .joined(separator: "\n---\n")
        }
        return """
        The user is currently working with their document "\(doc.title)". Most relevant excerpts for this request:
        \(excerpts)
        Answer from these excerpts when they cover the question — do NOT call search_docs (these are its results) and do NOT web-search for things the document already answers. If the excerpts don't cover the question, briefly say the document doesn't cover it, then answer normally.
        """
    }
}
