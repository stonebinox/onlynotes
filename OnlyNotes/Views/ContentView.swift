import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedNote: Note?

    var body: some View {
        NavigationSplitView {
            NoteListView(selectedNote: $selectedNote)
        } detail: {
            if let note = selectedNote {
                if note.isMeetingNote {
                    MeetingDetailView(note: note)
                        .id(note.id)
                } else {
                    NoteEditorView(note: note)
                        .id(note.id)
                }
            } else if appState.recorder.isRecording {
                LiveNotepadView()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "note.text")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.onFaintInk)
                    Text("Select a note or start recording")
                        .foregroundStyle(Color.onMutedInk)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { appState.loadNotes() }
        .onChange(of: appState.notes) { _, newNotes in
            if let sel = selectedNote,
               let updated = newNotes.first(where: { $0.id == sel.id }),
               updated.isMeetingNote != sel.isMeetingNote {
                selectedNote = updated
            }
        }
    }
}

// MARK: - Note Editor View

struct NoteEditorView: View {
    @EnvironmentObject var appState: AppState
    @State var note: Note
    @State private var tagDraft: String = ""
    @State private var saveTimer: Timer? = nil
    @State private var internalContextResults: [ContextResult] = []
    @State private var webContextResults: [ContextResult] = []
    @State private var contextError: String? = nil
    @State private var isLoadingContext = false
    @State private var contextTask: Task<Void, Never>? = nil
    @State private var lastTriggeredBody: String = ""
    @State private var showFilePicker = false

    var body: some View {
        HSplitView {
            editorPane
                .frame(minWidth: 300)
            contextPane
                .frame(minWidth: 240, maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showFilePicker = true }) {
                    Image(systemName: "waveform.badge.plus")
                }
                .help("Attach audio file")
                .disabled(appState.isImporting)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: exportNote) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export note as Markdown")
            }
        }
        .onDisappear {
            saveTimer?.invalidate()
            saveTimer = nil
            contextTask?.cancel()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let accessed = url.startAccessingSecurityScopedResource()
                // Copy file synchronously before releasing security scope
                let tempCopy = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: tempCopy)
                try? FileManager.default.copyItem(at: url, to: tempCopy)
                if accessed { url.stopAccessingSecurityScopedResource() }
                saveTimer?.invalidate()
                appState.importAudio(into: note.id, from: tempCopy)
            }
        }
        .alert("Import Failed", isPresented: Binding(
            get: { appState.importError != nil },
            set: { if !$0 { appState.importError = nil } }
        )) {
            Button("OK") { appState.importError = nil }
        } message: {
            Text(appState.importError ?? "")
        }
        .onAppear {
            if !note.body.isEmpty { refreshContext(query: buildQuery()) }
        }
        .id(note.id)
    }

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $note.title)
                .font(.title)
                .fontWeight(.semibold)
                .textFieldStyle(.plain)
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 8)
                .onChange(of: note.title) { _, _ in scheduleSave() }

            tagEditorView
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Divider()

            TextEditor(text: $note.body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .onChange(of: note.body) { _, new in
                    scheduleSave()
                    scheduleContextRefresh(body: new)
                }

            if appState.isImporting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Transcribing audio…").foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .onDrop(of: [.audio], isTargeted: nil) { providers in
            guard !appState.isImporting else { return false }
            guard let provider = providers.first else { return false }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, _ in
                guard let url = url else { return }
                let tempCopy = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: tempCopy)
                try? FileManager.default.copyItem(at: url, to: tempCopy)
                DispatchQueue.main.async {
                    self.saveTimer?.invalidate()
                    appState.importAudio(into: note.id, from: tempCopy)
                }
            }
            return true
        }
    }

    private var contextPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Context", systemImage: "sparkles")
                    .font(.onHeadline)
                    .foregroundStyle(Color.onInk)
                Spacer()
                if isLoadingContext {
                    ProgressView().controlSize(.small).tint(Color.onAccent)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.md)
            .background(Color.onPanel)

            Divider()

            if !isLoadingContext && internalContextResults.isEmpty && webContextResults.isEmpty {
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.onFaintInk)
                    Text("Context will appear\nas you write")
                        .font(.onCaption)
                        .foregroundStyle(Color.onFaintInk)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !internalContextResults.isEmpty {
                            sectionHeader("From your notes", icon: "note.text")
                            ForEach(internalContextResults) { result in
                                contextResultRow(result)
                                Divider().padding(.leading, 12)
                            }
                        }
                        if !webContextResults.isEmpty {
                            sectionHeader("From the web", icon: "globe")
                            ForEach(webContextResults) { result in
                                contextResultRow(result)
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            }
        }
        .background(Color.onPanel)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.onMutedInk)
            .textCase(.uppercase)
            .tracking(0.8)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.onPanel)
    }

    @ViewBuilder
    private func contextResultRow(_ result: ContextResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(result.title)
                .font(.onCaption)
                .fontWeight(.medium)
                .foregroundStyle(Color.onInk)
                .lineLimit(1)
            if !result.snippet.isEmpty {
                Text(result.snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.onMutedInk)
                    .lineLimit(3)
            }
            if case .web(let url) = result.source {
                Text(url)
                    .font(.onMeta)
                    .foregroundStyle(Color.onAccent)
                    .lineLimit(1)
                    .onTapGesture {
                        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                    }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tagEditorView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(note.tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text(tag).font(.caption)
                        Button(action: { removeTag(tag) }) {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.onSeparator.opacity(0.5), in: Capsule())
                }
                TextField("Add tag...", text: $tagDraft)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .frame(width: 80)
                    .onSubmit { commitTag() }
                    .onChange(of: tagDraft) { _, new in
                        if new.hasSuffix(",") { tagDraft = String(new.dropLast()); commitTag() }
                    }
            }
        }
    }

    private func scheduleSave() {
        guard !appState.isImporting else { saveTimer?.invalidate(); return }
        saveTimer?.invalidate()
        let capturedID = note.id
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [self] _ in
            guard note.id == capturedID else { return }
            var updated = note
            updated.updatedAt = Date()
            DispatchQueue.main.async {
                appState.saveNote(updated)
            }
        }
    }

    private func commitTag() {
        let trimmed = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { tagDraft = ""; return }
        var updated = note
        updated.setTags(note.tags + [trimmed])
        note = updated
        appState.saveNote(updated)
        tagDraft = ""
        refreshContext(query: buildQuery())
    }

    private func removeTag(_ tag: String) {
        var updated = note
        updated.setTags(note.tags.filter { $0 != tag })
        note = updated
        appState.saveNote(updated)
        refreshContext(query: buildQuery())
    }

    private func scheduleContextRefresh(body: String) {
        guard body.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else { return }
        let triggerOnSentence = body.count > lastTriggeredBody.count &&
            (body.hasSuffix(". ") || body.hasSuffix("? ") || body.hasSuffix("! ") || body.hasSuffix("\n"))

        if triggerOnSentence {
            lastTriggeredBody = body
            refreshContext(query: buildQuery())
            return
        }

        contextTask?.cancel()
        contextTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                lastTriggeredBody = note.body
                refreshContext(query: buildQuery())
            }
        }
    }

    private func buildQuery() -> String {
        let bodySnippet = String(note.body.suffix(300))
        let parts = [note.title, bodySnippet].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return parts.joined(separator: " ")
    }

    private func refreshContext(query: String) {
        let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTags = !note.tags.isEmpty
        guard hasTags || hasQuery else {
            internalContextResults = []
            webContextResults = []
            contextError = nil
            return
        }

        contextTask?.cancel()
        contextTask = Task {
            await MainActor.run { isLoadingContext = true; contextError = nil }

            let notes = appState.notes
            let braveKey = appState.braveSearchAPIKey
            let openAIKey = appState.openAIKey
            let currentTags = note.tags
            let currentID = note.id

            // Run all three sources in parallel
            async let tagResults: [ContextResult] = Task.detached { @Sendable in
                hasTags ? EmbeddingService.shared.findByTags(currentTags, among: notes, excludingID: currentID) : []
            }.value

            async let semanticResults: [ContextResult] = hasQuery
                ? EmbeddingService.shared.findSimilar(to: query, among: notes.filter { $0.id != currentID }, apiKey: openAIKey, topK: 5)
                : []

            async let webFetch: (results: [ContextResult], error: String?) = Task.detached { @Sendable in
                guard hasQuery else { return ([], nil) }
                do {
                    let results = try await BraveSearchService().search(query: query, apiKey: braveKey)
                    return (results, nil)
                } catch {
                    return ([], error.localizedDescription)
                }
            }.value

            let (tags, semantic, webData) = await (tagResults, semanticResults, webFetch)

            if Task.isCancelled {
                await MainActor.run { isLoadingContext = false }
                return
            }

            // Merge and dedupe internal results by note ID, keeping highest score
            var seenNoteIDs = Set<String>()
            var mergedInternal: [ContextResult] = []
            for result in (semantic + tags).sorted(by: { $0.score > $1.score }) {
                if seenNoteIDs.insert(result.id).inserted {
                    mergedInternal.append(result)
                }
            }

            await MainActor.run {
                self.internalContextResults = mergedInternal
                self.webContextResults = webData.results
                self.contextError = webData.error
                self.isLoadingContext = false
            }
        }
    }

    private func exportNote() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (note.title.isEmpty ? "note" : note.title)
            .replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines: [String] = []
        lines.append("# \(note.title.isEmpty ? "Untitled" : note.title)")
        lines.append(note.createdAt.formatted(date: .abbreviated, time: .shortened))
        if !note.tags.isEmpty {
            lines.append("Tags: \(note.tags.joined(separator: ", "))")
        }
        lines.append("")
        if !note.body.isEmpty {
            lines.append(note.body)
            lines.append("")
        }

        let markdown = lines.joined(separator: "\n")
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct LiveNotepadView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.onRecordActive)
                    .frame(width: 8, height: 8)
                Text("Live Notes")
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            if appState.liveNotes.isEmpty {
                Text("No notes yet. Jot down questions or key moments.")
                    .foregroundStyle(Color.onMutedInk)
                    .font(.subheadline)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.liveNotes) { note in
                            HStack(alignment: .top, spacing: 10) {
                                Text(note.formattedTimestamp)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 40, alignment: .leading)
                                Text(note.text)
                                    .font(.subheadline)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                TextField("Add a note...", text: $appState.liveNoteDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { appState.addLiveNote() }
                Button("Add", action: appState.addLiveNote)
                    .disabled(appState.liveNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
