import SwiftUI

struct SidebarView: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        List(selection: destinationBinding) {
            Section("Library") {
                SidebarDestinationRow(destination: .library, title: "All Models", symbol: "square.stack.3d.up",
                                      badge: store.modelCount)
                SidebarDestinationRow(destination: .pinned, title: "Pinned", symbol: "pin",
                                      badge: store.pinned.count)
                SidebarDestinationRow(destination: .recents, title: "Recents", symbol: "clock.arrow.circlepath",
                                      badge: store.recents.count)
            }

            Section {
                ForEach(store.providers) { provider in
                    SidebarProviderRow(provider: provider, status: store.status(of: provider)) {
                        workspace.destination = Destination.provider(provider.id)
                    } refreshAction: {
                        workspace.refresh(provider)
                    } editAction: {
                        workspace.edit(provider)
                    } removeAction: {
                        workspace.confirmRemoval(of: provider)
                    }
                }
                .onMove(perform: moveProviders)
            } header: {
                SidebarProvidersHeader {
                    workspace.addProvider()
                }
            }

            Section("Panel") {
                SidebarDestinationRow(destination: .overview, title: "Overview", symbol: "chart.bar.xaxis", badge: nil)
                SidebarDestinationRow(destination: .usage, title: "Usage", symbol: "list.bullet.rectangle", badge: nil)
                SidebarDestinationRow(destination: .accounts, title: "Accounts", symbol: "person.badge.key", badge: nil)
                SidebarDestinationRow(destination: .providersPage, title: "Models", symbol: "square.stack.3d.up.fill", badge: nil)
                SidebarDestinationRow(destination: .pricing, title: "Pricing", symbol: "tag", badge: nil)
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

    private func moveProviders(from source: IndexSet, to destination: Int) {
        store.moveProviders(from: source, to: destination)
    }
}

private struct SidebarDestinationRow: View {
    let destination: Destination
    let title: String
    let symbol: String
    let badge: Int?

    var body: some View {
        Label {
            HStack {
                Text(title)
                Spacer(minLength: 4)
                if let badge, badge > 0 {
                    Pill(text: String(badge))
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .tag(destination)
    }
}

private struct SidebarProvidersHeader: View {
    let addAction: () -> Void

    var body: some View {
        HStack {
            SectionHeader(title: "Providers")
            Spacer()
            Button(action: addAction) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Add a provider (⌘N)")
        }
    }
}

private struct SidebarProviderRow: View {
    let provider: Provider
    let status: ProviderStatus
    let selectAction: () -> Void
    let refreshAction: () -> Void
    let editAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Label {
                HStack {
                    Text(provider.name)
                    Spacer(minLength: 4)
                    statusTrailing
                }
            } icon: {
                StatusDot(tint: statusTint)
                    .padding(.trailing, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { selectAction() }
        }
        .contextMenu {
            Button("Refresh") { refreshAction() }
            Button("Edit…") { editAction() }
            Divider()
            Button("Remove…") { removeAction() }
        }
        .tag(Destination.provider(provider.id))
        .help("\(provider.host) · \(status.subtitle)")
    }

    @ViewBuilder
    private var statusTrailing: some View {
        switch status {
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .imageScale(.small)
        case .loading:
            ProgressView()
                .controlSize(.mini)
        case .ready(let count):
            Pill(text: String(count))
        case .empty:
            EmptyView()
        }
    }

    private var statusTint: Color {
        RavenTheme.statusTint(status)
    }
}
