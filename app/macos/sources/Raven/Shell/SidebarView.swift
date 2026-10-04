import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store

    var body: some View {
        List(selection: selection) {
            Section("Launch") {
                Label("Models", systemImage: "square.stack.3d.up")
                    .tag(Page.models)
                Label("Pinned", systemImage: "pin")
                    .tag(Page.pinned)
                Label("Recents", systemImage: "clock.arrow.circlepath")
                    .tag(Page.recents)
            }

            Section("Providers") {
                ProviderRow(provider: LocalProxy.provider)
                ForEach(store.customProviders) { provider in
                    ProviderRow(provider: provider)
                }
                .onMove { store.moveProviders(from: $0, to: $1) }
                Button {
                    app.addProvider()
                } label: {
                    Label("Add Provider", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add a provider (⌘N)")
            }

            Section("Proxy") {
                Label("Overview", systemImage: "chart.xyaxis.line").tag(Page.overview)
                Label("Usage", systemImage: "tablecells").tag(Page.usage)
                Label("Accounts", systemImage: "person.2.badge.key").tag(Page.accounts)
                Label("Routing", systemImage: "arrow.triangle.branch").tag(Page.routing)
                Label("Pricing", systemImage: "dollarsign").tag(Page.pricing)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                HealthBadge()
                Spacer()
            }
            .padding(Space.md)
        }
    }

    private var selection: Binding<Page?> {
        Binding(get: { app.page }, set: { if let page = $0 { app.page = page } })
    }
}

private struct ProviderRow: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store
    let provider: Provider

    var body: some View {
        let status = store.status(of: provider)
        Label {
            Text(provider.name).lineLimit(1)
        } icon: {
            switch status {
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .loading:
                ProgressView().controlSize(.small)
            default:
                if provider.isBuiltIn, let logo = RavenLogo.image {
                    Image(nsImage: logo)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundStyle(provider.accent)
                } else {
                    Image(systemName: "server.rack").foregroundStyle(provider.accent)
                }
            }
        }
        .tag(Page.provider(provider.id))
        .help("\(provider.host) · \(status.subtitle)")
        .contextMenu {
            Button("Refresh") { app.refresh(provider) }
            if !provider.isBuiltIn {
                Button("Edit…") { app.edit(provider) }
                Divider()
                Button("Remove…", role: .destructive) { app.confirmRemoval(of: provider) }
            }
        }
    }

}
