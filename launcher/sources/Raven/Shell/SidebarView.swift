import SwiftUI

struct SidebarView: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        List(selection: destinationBinding) {
            Section("Library") {
                row(.library, "All Models", store.modelCount)
                row(.pinned, "Pinned", store.pinned.count)
                row(.recents, "Recents", store.recents.count)
            }

            Section {
                ForEach(store.providers) { provider in
                    providerRow(provider)
                }
                .onMove(perform: moveProviders)
            } header: {
                HStack {
                    SectionHeader(title: "Providers")
                    Spacer()
                    Button {
                        workspace.addProvider()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Add a provider (⌘N)")
                }
            }

            Section("Panel") {
                row(.overview, "Overview", nil)
                row(.usage, "Usage", nil)
                row(.accounts, "Accounts", nil)
                row(.providersPage, "Models", nil)
                row(.pricing, "Pricing", nil)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(
            min: Metrics.sidebarMin,
            ideal: Metrics.sidebarIdeal,
            max: Metrics.sidebarMax)
    }

    private var destinationBinding: Binding<Destination?> {
        Binding(
            get: { workspace.destination },
            set: { if let value = $0 { workspace.destination = value } })
    }

    private func row(_ destination: Destination, _ title: String, _ badge: Int?) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer(minLength: 4)
                if let badge, badge > 0 {
                    Pill(text: String(badge))
                }
            }
        } icon: {
            Image(systemName: destination.symbol)
        }
        .tag(destination)
    }

    private func providerRow(_ provider: Provider) -> some View {
        let status = store.status(of: provider)
        return Label {
            HStack {
                Text(provider.name)
                Spacer(minLength: 4)
                if status.isFailure {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .imageScale(.small)
                } else if case .ready(let count) = status {
                    Pill(text: String(count))
                }
            }
        } icon: {
            Image(systemName: "server.rack")
                .foregroundStyle(RavenTheme.providerAccent(provider))
        }
        .tag(Destination.provider(provider.id))
        .help("\(provider.host) · \(status.subtitle)")
        .contextMenu {
            Button("Refresh") { workspace.refresh(provider) }
            Button("Edit…") { workspace.edit(provider) }
            Divider()
            Button("Remove…") { workspace.confirmRemoval(of: provider) }
        }
    }

    private func moveProviders(from source: IndexSet, to destination: Int) {
        store.moveProviders(from: source, to: destination)
    }
}
