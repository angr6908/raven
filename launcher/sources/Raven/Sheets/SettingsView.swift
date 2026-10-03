import SwiftUI

struct SettingsView: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        TabView {
            LaunchSettingsView(store: store, workspace: workspace)
                .tabItem { Label("Launch", systemImage: "play.circle") }
            ProvidersSettingsView(store: store, workspace: workspace)
                .tabItem { Label("Providers", systemImage: "server.rack") }
        }
        .frame(width: 520, height: 360)
    }
}

struct LaunchSettingsView: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        Form {
            Picker("Client", selection: clientBinding) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("Folder") {
                Button(store.workdirLabel) { workspace.chooseWorkdir() }
                    .help(store.workdirPath)
            }

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

            Section {
                Text("Providers, keys and preferences live in \(ProviderStore.configFile.path(percentEncoded: false)).")
                    .font(RavenFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(Metrics.spacing3)
    }

    private var clientBinding: Binding<ProviderKind> {
        Binding(get: { store.client }, set: { store.client = $0 })
    }
}

struct ProvidersSettingsView: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    workspace.addProvider()
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
            }
            .padding(.horizontal, Metrics.spacing3)
            .padding(.vertical, Metrics.spacing2)

            List {
                ForEach(store.providers) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                            Text("\(provider.rootURL) · \(store.status(of: provider).subtitle)")
                                .font(RavenFont.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Edit…") { workspace.edit(provider) }
                            .controlSize(.small)
                        Button {
                            workspace.confirmRemoval(of: provider)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                        .help("Remove provider")
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}
