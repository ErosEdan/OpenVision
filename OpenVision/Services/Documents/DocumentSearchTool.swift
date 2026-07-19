// OpenVision - DocumentSearchTool.swift
// Native tool giving every backend grounded access to the user's imported documents (manuals,
// recipes, guides). The model calls it with a query; the store returns the best excerpts; the
// model answers FROM those excerpts instead of inventing details. Import happens in Settings →
// My Documents (voice import is not a v1 feature).

import Foundation

struct DocumentSearchTool: NativeTool {
    let name = "search_docs"
    let description = "Work with the user's imported documents (manuals, recipes, guides, instructions). Actions: 'search' (needs query — return the most relevant passages; use whenever the user asks about their documents), 'list' (name the imported documents), 'focus' (needs query naming the document — the user wants to work with one document, e.g. 'open my router manual'; its content will then be checked first for every question), 'unfocus' (the user is done with the document, e.g. 'close the document')."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "description": "search, list, focus, or unfocus"],
            "query": ["type": "string", "description": "What to look for (search), or the document name (focus)"]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        switch (args["action"] as? String ?? "search").lowercased() {
        case "focus", "open":
            guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !query.isEmpty else { return "Which document should I open?" }
            let docs = DocumentStore.shared.documents()
            guard !docs.isEmpty else {
                return "No documents imported yet. Documents can be added in Settings under My Documents."
            }
            guard let index = DocumentChunking.bestTitleMatch(query: query, titles: docs.map(\.title)) else {
                let names = docs.prefix(5).map(\.title).joined(separator: ", ")
                return "I couldn't find a document matching '\(query)'. You have: \(names)."
            }
            let doc = docs[index]
            await MainActor.run { DocumentFocus.shared.activate(doc) }
            return "Focused on \(doc.title). I'll check it first for your questions — say 'close the document' when you're done."

        case "unfocus", "close":
            let title = await MainActor.run { () -> String? in
                let t = DocumentFocus.shared.activeDocument?.title
                DocumentFocus.shared.deactivate()
                return t
            }
            return title.map { "Closed \($0)." } ?? "No document was open."

        case "list":
            let docs = DocumentStore.shared.documents()
            guard !docs.isEmpty else {
                return "No documents imported yet. Documents can be added in Settings under My Documents."
            }
            let names = docs.prefix(10).map { "\($0.title) (\($0.chunks.count) sections)" }
            return "\(docs.count) document\(docs.count == 1 ? "" : "s"): " + names.joined(separator: "; ")

        default:   // search
            guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !query.isEmpty else {
                return "What should I look for in your documents?"
            }
            let hits = DocumentStore.shared.search(query, k: 3)
            guard !hits.isEmpty else {
                let docs = DocumentStore.shared.documents()
                return docs.isEmpty
                    ? "No documents imported yet. Documents can be added in Settings under My Documents."
                    : "Nothing in your documents matches '\(query)'."
            }
            // Excerpts are capped (Apple's on-device model has a 4096-token context window, and
            // three full ~900-char chunks + web-search results overflowed it — seen on device),
            // but windowed around the query's keywords so the asked-about sentence survives.
            let body = hits
                .map { "[\($0.documentTitle)]\n\(DocumentChunking.relevantWindow(text: $0.text, query: query, limit: 400))" }
                .joined(separator: "\n---\n")
            return "Relevant excerpts from the user's documents — answer using ONLY this information and say so if it doesn't cover the question. Do not web-search for things the documents already answer:\n\(body)"
        }
    }
}
