import SwiftUI

struct SourceDetail: View {
    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared
    let source: RouteSource

    var body: some View {
        Group {
            if case .provider(let id) = source, nav.tab == .connection {
                ConnectionForm(id: id)
            } else {
                ModelsEditor(source: source)
            }
        }
        .task {
            if source == .channel("antigravity") { store.loadAntigravityLevels() }
        }
    }
}

private struct ConnectionForm: View {
    enum TestState: Equatable {
        case idle, testing, success(Int), failure(String)
    }

    private let store = ProvidersPanelStore.shared
    let id: UUID
    @State private var reveal = false
    @State private var test = TestState.idle
    @FocusState private var nameFocused: Bool

    var body: some View {
        let source = RouteSource.provider(id)
        if let entry = store.entry(source), let index = store.index(of: source) {
            let issues = RoutingTable.issues(at: index, in: store.list)
            Form {
                Section {
                    TextField(text: Binding(
                        get: { entry.name },
                        set: { text in store.edit(source) { $0.name = text } }),
                        prompt: Text(verbatim: "openrouter")) {
                        FieldLabel(title: "Name", issue: issues.first { $0 == .missingName || $0 == .duplicateName })
                    }
                    .font(.identifier)
                    .focused($nameFocused)
                    TextField(text: Binding(
                        get: { entry.baseUrl ?? "" },
                        set: { text in store.edit(source) { $0.baseUrl = text } }),
                        prompt: Text(verbatim: "https://api.example.com/v1")) {
                        FieldLabel(title: "Base URL", issue: issues.first { $0 == .missingURL || $0 == .invalidURL })
                    }
                    .font(.identifier)
                    Picker("Protocol", selection: Binding(
                        get: { entry.usableKind },
                        set: { value in store.edit(source) { $0.kind = value } })) {
                        Text("Chat Completions").tag("openai")
                        Text("Responses").tag("responses")
                    }
                }

                Section {
                    if entry.apiKeyEntries.isEmpty {
                        LabeledContent {
                            Button("Add Key") {
                                store.edit(source) { $0.apiKeyEntries.append(ApiKeyEntry(apiKey: "")) }
                            }
                        } label: {
                            FieldLabel(title: "Active Key", issue: issues.first { $0 == .missingKey })
                        }
                    }
                    ForEach(entry.apiKeyEntries.indices, id: \.self) { keyIndex in
                        KeyRow(source: source, index: keyIndex, entry: entry.apiKeyEntries[keyIndex],
                               count: entry.apiKeyEntries.count, reveal: reveal,
                               issue: keyIndex == 0 ? issues.first { $0 == .missingKey } : nil)
                    }
                    if !entry.apiKeyEntries.isEmpty {
                        Toggle("Show Keys", isOn: $reveal)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        LabeledContent("Spare Keys") {
                            Button("Add Key") {
                                store.edit(source) { $0.apiKeyEntries.append(ApiKeyEntry(apiKey: "")) }
                            }
                        }
                    }
                }

                Section {
                    LabeledContent("Connection") {
                        HStack(spacing: Space.md) {
                            TestStatus(state: test)
                            Button("Test") { run() }
                                .disabled(test == .testing || issues.contains(where: \.blocking))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear {
                if entry.name.isEmpty { nameFocused = true }
            }
        }
    }

    private func run() {
        test = .testing
        Task {
            do {
                let models = try await store.catalog(for: .provider(id))
                test = .success(models.count)
            } catch {
                test = .failure((error as? PanelError)?.noticeText ?? error.localizedDescription)
            }
        }
    }
}

private struct KeyRow: View {
    private let store = ProvidersPanelStore.shared
    let source: RouteSource
    let index: Int
    let entry: ApiKeyEntry
    let count: Int
    let reveal: Bool
    let issue: ProviderIssue?

    var body: some View {
        LabeledContent {
            HStack(spacing: Space.sm) {
                Group {
                    if reveal {
                        TextField("API Key", text: binding, prompt: Text(verbatim: "sk-…"))
                    } else {
                        SecureField("API Key", text: binding, prompt: Text(verbatim: "sk-…"))
                    }
                }
                .labelsHidden()
                .font(.identifier)
                if index > 0 || count > 1 || !entry.apiKey.isEmpty {
                    Menu {
                        if index > 0 {
                            Button("Make Active") {
                                store.edit(source) { provider in
                                    guard index < provider.apiKeyEntries.count else { return }
                                    let key = provider.apiKeyEntries.remove(at: index)
                                    provider.apiKeyEntries.insert(key, at: 0)
                                }
                            }
                        }
                        Button("Remove Key", systemImage: "trash", role: .destructive) {
                            store.edit(source) { provider in
                                guard index < provider.apiKeyEntries.count else { return }
                                provider.apiKeyEntries.remove(at: index)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                }
            }
        } label: {
            FieldLabel(title: index == 0 ? "Active Key" : "Spare Key \(index)", issue: issue)
        }
    }

    private var binding: Binding<String> {
        Binding(
            get: { entry.apiKey },
            set: { text in
                store.edit(source) { provider in
                    guard index < provider.apiKeyEntries.count else { return }
                    provider.apiKeyEntries[index].apiKey = text
                }
            })
    }
}

private struct FieldLabel: View {
    let title: String
    let issue: ProviderIssue?

    var body: some View {
        Text(title)
        if let issue {
            Text(issue.message)
                .foregroundStyle(issue.blocking ? .red : .orange)
        }
    }
}

private struct TestStatus: View {
    let state: ConnectionForm.TestState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            }
        case .success(let count):
            Label(count == 1 ? "Connected · 1 model" : "Connected · \(count) models",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.good)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
                .textSelection(.enabled)
        }
    }
}
