import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var store = store
        @Bindable var workspace = workspace
        NavigationSplitView {
            Sidebar()
        } detail: {
            Detail()
        }
        .sheet(item: $workspace.providerDraft) { draft in
            ProviderSheet(draft: draft)
        }
        .sheet(item: $workspace.windowDraft) { draft in
            ContextWindowSheet(draft: draft)
        }
        .sheet(isPresented: $workspace.isShowingScript) {
            ScriptSheet()
        }
        .confirmationDialog("Remove this provider?",
                            isPresented: $workspace.isConfirmingRemoval,
                            titleVisibility: .visible,
                            presenting: workspace.pendingRemoval) { provider in
            Button("Remove \(provider.name)", role: .destructive) {
                workspace.removePendingProvider()
            }
            Button("Cancel", role: .cancel) {}
        } message: { provider in
            Text("Raven forgets \(provider.name)'s base URL and API key, along with its pins and context window overrides.")
        }
        .alert("Couldn't launch", isPresented: $workspace.isShowingLaunchError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.launchError ?? "")
        }
        .fileImporter(isPresented: $workspace.isChoosingWorkdir, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                store.workdir = url
            }
        }
        .fileDialogDefaultDirectory(store.workdir)
        .fileDialogMessage("Choose the folder to launch in")
        .fileDialogConfirmationLabel("Use Folder")
    }
}

struct Detail: View {
    @Environment(ProviderStore.self) private var store

    var body: some View {
        if store.providers.isEmpty {
            Welcome()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.windowBackground)
                .navigationTitle("Raven")
        } else {
            Browser()
        }
    }
}

struct Browser: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        Group {
            if case .recents = workspace.destination {
                RecentsList()
            } else {
                ModelList()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
        .navigationTitle(workspace.title)
        .navigationSubtitle(workspace.subtitle)
        .safeAreaBar(edge: .bottom) {
            LaunchBar()
        }
        .searchable(text: $workspace.search, placement: .toolbar, prompt: "Search models")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    workspace.refreshActive()
                }
                .symbolEffect(.rotate, isActive: store.isRefreshing)
                .disabled(store.isRefreshing)
                .help("Reload the model list (⌘R)")
            }
        }
    }
}

struct Welcome: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Raven", systemImage: "bird.fill")
        } description: {
            Text("Add an OpenAI-compatible endpoint. Raven lists its models and launches Claude Code or Codex against whichever one you pick.")
        } actions: {
            Button("Add Provider…", systemImage: "plus") {
                workspace.addProvider()
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            Button("Use the Local Raven Proxy") {
                workspace.addLocalProxy()
            }
            .buttonStyle(.link)
            .help("Prefill \(LocalProxy.baseURL)")
        }
    }
}
