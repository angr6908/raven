import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store
    private let panel = ProvidersPanelStore.shared

    var body: some View {
        List(selection: selection) {
            Section("Launch") {
                Label("Models", systemImage: "cube")
                    .tag(Page.models)
                Label("Pinned", systemImage: "pin")
                    .tag(Page.pinned)
            }

            Section("Providers") {
                ForEach(ChannelSpec.all) { spec in
                    SourceRow(source: .channel(spec.kind))
                }
                ForEach(panel.upstreams, id: \.id) { item in
                    SourceRow(source: .provider(item.id))
                }
                .onMove { panel.moveUpstreams(from: $0, to: $1) }
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
                Label("Overview", systemImage: "gauge.with.dots.needle.33percent").tag(Page.overview)
                Label("Usage", systemImage: "chart.bar").tag(Page.usage)
                Label("Accounts", systemImage: "person.2").tag(Page.accounts)
                Label("Pricing", systemImage: "tag").tag(Page.pricing)
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            switch app.page {
            case .source(.provider(let id)):
                app.sourceRemoval = id
            case .provider:
                if let provider = app.focusedProvider, !provider.isBuiltIn { app.confirmRemoval(of: provider) }
            default:
                break
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                HealthBadge()
                Spacer()
            }
            .padding(Space.md)
        }
        .task {
            await CoreProcess.shared.waitUntilReady()
            panel.start()
        }
        .onChange(of: UsageStore.shared.isProxyUp) { _, up in
            if up, panel.providers == nil { panel.reload() }
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
                Image(systemName: "link")
            }
        }
        .tag(Page.provider(provider.id))
        .help("Direct · \(provider.host) · \(status.subtitle)")
        .contextMenu {
            Button("Refresh") { app.refresh(provider) }
            Button("Edit…") { app.edit(provider) }
            Divider()
            Button("Remove…", role: .destructive) { app.confirmRemoval(of: provider) }
        }
    }

}

private struct SourceRow: View {
    private let panel = ProvidersPanelStore.shared
    let source: RouteSource

    var body: some View {
        let entry = panel.entry(source)
        Label {
            Text(panel.title(of: source)).lineLimit(1)
        } icon: {
            if panel.syncErrors[source] != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if panel.blocked(source) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if case .channel(let kind) = source, let logo = ChannelLogo.image(kind) {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "globe")
            }
        }
        .opacity(entry?.disabled == true ? 0.45 : 1)
        .tag(Page.source(source))
        .help(help(entry))
        .contextMenu { SourceMenu(source: source) }
    }

    private func help(_ entry: ProviderEntry?) -> String {
        let count = entry?.models.count ?? 0
        let models = count == 1 ? "1 model" : "\(count) models"
        switch source {
        case .channel:
            return "Via Raven · \(panel.title(of: source)) accounts · \(models)"
        case .provider:
            let base = (entry?.baseUrl ?? "").trimmingCharacters(in: .whitespaces)
            return "Via Raven · \(URL(string: base)?.host() ?? base) · \(models)"
        }
    }
}
