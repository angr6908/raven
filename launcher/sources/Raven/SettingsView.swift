import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Launch", systemImage: "play.circle") {
                LaunchSettings()
            }
            Tab("Providers", systemImage: "server.rack") {
                ProviderSettings()
            }
        }
        .frame(width: 480, height: 300)
    }
}

struct LaunchSettings: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("Client", selection: $store.client) {
                    ForEach(ProviderKind.allCases) { kind in
                        Label(kind.displayName, systemImage: kind.symbol).tag(kind)
                    }
                }
                LabeledContent("Folder") {
                    Button(store.workdirLabel, systemImage: "folder") {
                        workspace.chooseWorkdir()
                    }
                    .help(store.workdirPath)
                }
            }
            Section {
                LabeledContent("Recent launches") {
                    Button("Clear") { store.clearRecents() }
                        .disabled(store.recents.isEmpty)
                }
                LabeledContent("Context window overrides") {
                    Button("Reset All") { store.clearWindowOverrides() }
                        .disabled(store.windowOverrides.isEmpty)
                }
                LabeledContent("Configuration file") {
                    Button("Show in Finder") { workspace.revealConfig() }
                }
            } footer: {
                Text("Providers, keys and preferences live in \(Text(ProviderStore.configFile.path(percentEncoded: false)).monospaced()).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ProviderSettings: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Form {
            Section {
                if store.providers.isEmpty {
                    ContentUnavailableView {
                        Label("No providers", systemImage: "server.rack")
                    } description: {
                        Text("Add an OpenAI-compatible endpoint to get started.")
                    }
                }
                ForEach(store.providers) { provider in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Button("Edit…") { workspace.edit(provider) }
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                workspace.confirmRemoval(of: provider)
                            }
                            .labelStyle(.iconOnly)
                        }
                    } label: {
                        Text(provider.name)
                        Text("\(provider.rootURL) · \(store.status(of: provider).subtitle)")
                    }
                }
            } header: {
                HStack(spacing: 0) {
                    Text("Providers")
                    Spacer()
                    Button("Add Provider", systemImage: "plus") {
                        workspace.addProvider()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
    }
}
