import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ProviderStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            ProviderSidebar()
        } detail: {
            ProviderDetail()
        }
        .sheet(item: $store.providerDraft) { draft in
            ProviderEditView(draft: draft)
        }
        .sheet(item: $store.windowDraft) { draft in
            WindowEditView(draft: draft)
        }
        .confirmationDialog("Remove this provider?",
                            isPresented: $store.isConfirmingRemoval,
                            presenting: store.pendingRemoval) { provider in
            Button("Remove \(provider.name)", role: .destructive) {
                store.removeProvider(provider)
            }
            Button("Cancel", role: .cancel) {}
        } message: { provider in
            Text("Raven will forget \(provider.name)'s base URL and API key. This can't be undone.")
        }
        .alert("Launch failed", isPresented: $store.isShowingLaunchError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.launchError ?? "")
        }
        .fileImporter(isPresented: $store.isChoosingWorkdir, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                store.workdir = url
            }
        }
        .fileDialogDefaultDirectory(store.workdir)
        .fileDialogMessage("Choose the working directory for the launched client")
        .fileDialogConfirmationLabel("Use Folder")
    }
}

struct ProviderSidebar: View {
    @Environment(ProviderStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedProviderID) {
            Section("Providers") {
                ForEach(store.providers) { provider in
                    ProviderRow(provider: provider, status: store.status(of: provider))
                        .contextMenu {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await store.refresh(provider) }
                            }
                            Button("Edit…", systemImage: "square.and.pencil") {
                                store.beginEditing(provider)
                            }
                            Divider()
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                store.pendingRemoval = provider
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        .safeAreaBar(edge: .bottom) {
            HStack {
                Button("Add Provider", systemImage: "plus") {
                    store.beginAddingProvider()
                }
                .buttonStyle(.glass)
                Spacer()
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Refresh All", systemImage: "arrow.clockwise") {
                        Task { await store.refreshAll() }
                    }
                    .buttonStyle(.glass)
                    .labelStyle(.iconOnly)
                    .disabled(store.providers.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct ProviderRow: View {
    let provider: Provider
    let status: ProviderStatus

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if status == .loading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(status.subtitle)
                    .font(.caption)
                    .foregroundStyle(status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch status {
        case .failed: .red
        case .ready: .green
        case .loading, .empty: .secondary
        }
    }
}
