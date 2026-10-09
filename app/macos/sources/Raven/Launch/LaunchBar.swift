import SwiftUI

extension View {
    func launchChrome() -> some View {
        modifier(LaunchChrome())
    }
}

private struct LaunchChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                LaunchBar()
            }
    }
}

struct LaunchBar: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store
    @State private var customWindow = false
    @State private var customText = ""

    var body: some View {
        HStack(spacing: Space.lg) {
            target
            Spacer(minLength: Space.md)
            Picker("Client", selection: Binding(get: { store.client }, set: { store.client = $0 })) {
                ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Which client to start")
            FolderMenu()
            if let item = store.selectedItem {
                contextMenu(item)
            }
            Button {
                app.launch()
            } label: {
                Label(app.isLaunching ? "Launching…" : "Launch", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent)
            .disabled(!store.canLaunch || app.isLaunching)
            .help("Open Terminal and start the selected model (⌘↩)")
        }
        .controlSize(.large)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.md)
        .alert("Custom Context Window", isPresented: $customWindow) {
            TextField("e.g. 350k", text: $customText)
            Button("Cancel", role: .cancel) {}
            Button("Set") {
                if let item = store.selectedItem, let tokens = PanelFormats.parseTokenCount(customText) {
                    store.setWindowOverride(item.ref, tokens: tokens)
                }
            }
        } message: {
            Text("Where the client's context bar fills and auto-compaction fires.")
        }
    }

    @ViewBuilder
    private var target: some View {
        if let item = store.selectedItem {
            HStack(spacing: Space.md) {
                FamilyGlyph(family: item.entry.family, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.entry.modelID)
                        .font(.identifier.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(app.providerTitle(item))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button {
                    store.togglePin(item)
                } label: {
                    Image(systemName: store.isPinned(item) ? "pin.fill" : "pin")
                        .foregroundStyle(store.isPinned(item) ? Color.orange : .secondary)
                }
                .buttonStyle(.borderless)
                .help(store.isPinned(item) ? "Unpin (⌘D)" : "Pin (⌘D)")
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("Select a model").font(.headline)
                Text("Pick one above, then launch.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private enum WindowChoice: Hashable {
        case reported
        case preset(Int)
        case custom
    }

    private func contextMenu(_ item: ModelItem) -> some View {
        let override = store.windowOverride(providerID: item.provider.id, modelID: item.entry.modelID)
        let current: WindowChoice = override.map { ContextWindow.presets.contains($0) ? .preset($0) : .custom } ?? .reported
        return Picker("Context Window", selection: Binding(
            get: { current },
            set: { choice in
                switch choice {
                case .reported: store.setWindowOverride(item.ref, tokens: nil)
                case .preset(let tokens): store.setWindowOverride(item.ref, tokens: tokens)
                case .custom:
                    customText = override.map(String.init) ?? ""
                    customWindow = true
                }
            })) {
            Text(reportedTitle(item)).tag(WindowChoice.reported)
            Divider()
            ForEach(ContextWindow.presets, id: \.self) { preset in
                Text(ContextWindow.compact(preset)).tag(WindowChoice.preset(preset))
            }
            Divider()
            Text(current == .custom ? "Custom · \(ContextWindow.compact(override ?? 0))" : "Custom…").tag(WindowChoice.custom)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("Context window: where the client's context bar fills and auto-compaction fires")
    }

    private func reportedTitle(_ item: ModelItem) -> String {
        if let advertised = item.entry.contextWindow { return "Reported · \(ContextWindow.compact(advertised))" }
        return "Default · \(ContextWindow.compact(ContextWindow.fallback))"
    }
}

struct FolderMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store

    var body: some View {
        Menu {
            let recents = store.recentWorkdirs.filter { $0 != store.workdir }
            if !recents.isEmpty {
                Section("Recent Folders") {
                    ForEach(recents, id: \.path) { url in
                        Button(url.lastPathComponent) { app.setWorkdir(url) }
                    }
                }
            }
            Button("Home") { app.setWorkdir(.homeDirectory) }
            Divider()
            Button("Choose Folder…") { app.isChoosingFolder = true }
            Button("Show in Finder") { app.revealWorkdir() }
        } label: {
            Label(store.workdirLabel, systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 130)
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Launch in \(store.workdirPath) (⇧⌘O to change)")
    }
}
