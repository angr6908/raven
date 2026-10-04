import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Launch", systemImage: "play") { LaunchSettings() }
            Tab("Providers", systemImage: "server.rack") { ProviderSettings() }
            Tab("Data", systemImage: "externaldrive") { DataSettings() }
        }
        .frame(width: 540, height: 400)
    }
}

private struct LaunchSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Client", selection: Binding(get: { store.client }, set: { store.client = $0 })) {
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Folder") {
                    Button(store.workdirLabel) { app.isChoosingFolder = true }
                        .help(store.workdirPath)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(store.providers) { provider in
                    HStack(spacing: Space.md) {
                        Glyph(symbol: "server.rack", tint: provider.accent, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                            Text("\(provider.rootURL) · \(store.status(of: provider).subtitle)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Edit…") { app.edit(provider) }
                        Button(role: .destructive) {
                            app.confirmRemoval(of: provider)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Remove provider")
                    }
                }
                .onMove { store.moveProviders(from: $0, to: $1) }
            }
            .listStyle(.inset)
            .overlay {
                if store.providers.isEmpty {
                    EmptyState(symbol: "server.rack", title: "No Providers")
                }
            }

            Divider()
            HStack {
                Button("Add Provider…", systemImage: "plus") { app.addProvider() }
                Spacer()
            }
            .padding(Space.md)
        }
    }
}

private struct DataSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store

    var body: some View {
        Form {
            Section {
                LabeledContent("Recent launches") {
                    Button("Clear") { store.clearRecents() }
                        .disabled(store.recents.isEmpty)
                }
                LabeledContent("Context window overrides") {
                    Button("Reset All") { store.clearWindowOverrides() }
                        .disabled(store.windowOverrides.isEmpty)
                }
            }
            Section {
                LabeledContent("Configuration file") {
                    Button("Show in Finder") { app.revealConfig() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
