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
    @State private var webState: WebContextState = .idle
    @State private var isLoadingContext = false
    @State private var contextTask: Task<Void, Never>? = nil
    @State private var lastTriggeredBody: String = ""
    @State private var lastContextQuery: String? = nil
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
                let tempCopy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                do {
                    try? FileManager.default.removeItem(at: tempCopy)
                    try FileManager.default.copyItem(at: url, to: tempCopy)
                    if accessed { url.stopAccessingSecurityScopedResource() }
                    saveTimer?.invalidate()
                    appState.importAudio(into: note.id, from: tempCopy)
                } catch {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                    appState.importError = "Could not access selected file: \(error.localizedDescription)"
                }
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
            if !note.body.isEmpty || !note.title.isEmpty { refreshContext(query: buildQuery()) }
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
                .onChange(of: note.title) { _, _ in
                    scheduleSave()
                    scheduleTitleContextRefresh()
                }

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
                    .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                do {
                    try? FileManager.default.removeItem(at: tempCopy)
                    try FileManager.default.copyItem(at: url, to: tempCopy)
                    DispatchQueue.main.async {
                        self.saveTimer?.invalidate()
                        appState.importAudio(into: note.id, from: tempCopy)
                    }
                } catch {
                    let msg = "Could not access dropped file: \(error.localizedDescription)"
                    DispatchQueue.main.async {
                        appState.importError = msg
                    }
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

            if !isLoadingContext && internalContextResults.isEmpty && isWebIdle {
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
                        if !isWebIdle {
                            sectionHeader("From the web", icon: "globe")
                            webStateView
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

    private var isWebIdle: Bool {
        if case .idle = webState { return true }
        return false
    }

    @ViewBuilder
    private var webStateView: some View {
        switch webState {
        case .idle:
            EmptyView()
        case .disabled:
            statusRow(icon: "exclamationmark.triangle", text: "Brave API key not set in Settings", color: Color(red: 0.85, green: 0.45, blue: 0.10))
        case .loading:
            statusRow(icon: "ellipsis.circle", text: "Searching the web…", color: Color.onMutedInk)
        case .failed(let msg):
            statusRow(icon: "exclamationmark.triangle", text: msg, color: Color(red: 0.85, green: 0.45, blue: 0.10))
        case .noResults:
            statusRow(icon: "magnifyingglass", text: "No web results found", color: Color.onMutedInk)
        case .answer(let answer):
            Button(action: { insertWebAnswer(answer) }) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(answer.text)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.onInk)
                        .lineLimit(8)
                    if !answer.citations.isEmpty {
                        ForEach(answer.citations.prefix(3), id: \.url) { cite in
                            Text(cite.title.isEmpty ? cite.url : cite.title)
                                .font(.onMeta)
                                .foregroundStyle(Color.onAccent)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func statusRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.onCaption)
                .foregroundStyle(Color.onMutedInk)
                .lineLimit(3)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func contextResultRow(_ result: ContextResult) -> some View {
        Button(action: { insertContextResult(result) }) {
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
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private func insertWebAnswer(_ answer: WebAnswer) {
        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        var insertion = text
        if !answer.citations.isEmpty {
            let citationLines = answer.citations.prefix(3).map { cite in
                let label = cite.title.isEmpty ? cite.url : cite.title
                return "- [\(label)](<\(cite.url)>)"
            }
            insertion += "\n\nSources:\n" + citationLines.joined(separator: "\n")
        }

        let separator = note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
        note.body += separator + insertion
        note.updatedAt = Date()
        appState.saveNote(note)
    }

    private func insertContextResult(_ result: ContextResult) {
        let snippet = result.snippet.trimmingCharacters(in: .whitespacesAndNewlines)

        let reference: String
        switch result.source {
        case .internalNote(let id):
            // Look up fresh title from appState
            let freshTitle = appState.notes.first(where: { $0.id == id })?.title ?? result.title
            let title = freshTitle.isEmpty ? "Untitled" : freshTitle
            reference = "[Source: \(title)](onlynotes://note/\(id.uuidString))"
        case .web(let url):
            reference = "[Source](<\(url)>)"
        }

        let insertion: String
        if snippet.isEmpty {
            insertion = reference
        } else {
            insertion = "\(snippet)\n\(reference)"
        }

        let separator = note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
        note.body += separator + insertion
        note.updatedAt = Date()
        appState.saveNote(note)
    }

    private func scheduleTitleContextRefresh() {
        contextTask?.cancel()
        contextTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                refreshContext(query: buildQuery())
            }
        }
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
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuery = !normalizedQuery.isEmpty
        let hasTags = !note.tags.isEmpty
        guard hasTags || hasQuery else {
            internalContextResults = []
            webState = .idle
            return
        }

        let cacheKey = normalizedQuery + "\u{1}" + note.tags.sorted().joined(separator: ",")
        if hasQuery && cacheKey == lastContextQuery {
            return
        }
        if hasQuery {
            lastContextQuery = cacheKey
        }

        contextTask?.cancel()
        contextTask = Task {
            await MainActor.run {
                isLoadingContext = true
                if hasQuery {
                    webState = .loading
                }
            }

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

            async let webFetch: WebContextState = {
                guard hasQuery else { return .idle }
                guard !braveKey.isEmpty else { return .disabled }
                guard !openAIKey.isEmpty else { return .failed("OpenAI API key not set in Settings") }
                do {
                    let results = try await BraveSearchService().search(query: query, apiKey: braveKey)
                    if results.isEmpty { return .noResults }
                    let openAI = OpenAIService(apiKey: openAIKey)
                    let answer = try await openAI.synthesizeWebAnswer(query: query, results: results)
                    return .answer(answer)
                } catch {
                    return .failed(error.localizedDescription)
                }
            }()

            let (tags, semantic, newWebState) = await (tagResults, semanticResults, webFetch)

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
                self.webState = newWebState
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
