// OpenVision - DocumentsSettingsView.swift
// Import and manage the documents behind the `search_docs` tool (RAG): PDFs/text files are
// chunked and embedded ON-DEVICE (NLEmbedding) so the assistant can answer questions grounded in
// the user's own manuals, recipes, and guides. Nothing leaves the phone.

import SwiftUI
import UniformTypeIdentifiers

struct DocumentsSettingsView: View {
    @State private var documents: [StoredDocument] = []
    @State private var showImporter = false
    @State private var importing = false
    @State private var errorMessage: String?
    @StateObject private var focus = DocumentFocus.shared

    var body: some View {
        Form {
            Section {
                if documents.isEmpty && !importing {
                    Text("No documents yet. Import a manual, recipe, or guide — then ask about it by voice: “what does my router manual say about error 5?”")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(documents) { doc in
                    HStack {
                        Image(systemName: doc.source == "pdf" ? "doc.richtext" : "doc.plaintext")
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title).lineLimit(1)
                            Text("\(doc.chunks.count) sections · \(doc.addedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        // Focus toggle — the visual twin of "Vision, open my <doc>". Filled book =
                        // this document is open and checked first for every question.
                        Button {
                            if focus.activeDocument?.id == doc.id {
                                focus.deactivate()
                            } else {
                                focus.activate(doc)
                            }
                        } label: {
                            Image(systemName: focus.activeDocument?.id == doc.id ? "book.fill" : "book")
                                .foregroundColor(focus.activeDocument?.id == doc.id ? .indigo : .secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet { DocumentStore.shared.remove(id: documents[index].id) }
                    reload()
                }
                if importing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Importing — extracting and indexing…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Imported Documents")
            } footer: {
                Text("Documents are indexed entirely on-device and never uploaded. Any backend can search them via the search_docs tool.")
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("Import PDF or Text File", systemImage: "plus.circle.fill")
                }
                .disabled(importing)
            }
        }
        .navigationTitle("My Documents")
        .onAppear(perform: reload)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.pdf, .plainText, .text],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importFile(url)
        }
        .alert("Import failed", isPresented: .init(get: { errorMessage != nil },
                                                   set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reload() {
        documents = DocumentStore.shared.documents()
    }

    private func importFile(_ url: URL) {
        importing = true
        Task.detached(priority: .userInitiated) {
            // fileImporter URLs are security-scoped; access must be explicitly claimed.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try DocumentStore.shared.importFile(at: url)
                await MainActor.run { importing = false; reload() }
            } catch {
                await MainActor.run {
                    importing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
