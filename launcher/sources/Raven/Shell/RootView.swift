import SwiftUI

struct RootView: View {
    let store: ProviderStore
    let workspace: Workspace
    @Bindable var shell: ShellState

    var body: some View {
        NavigationSplitView(columnVisibility: $shell.columnVisibility) {
            SidebarView(store: store, workspace: workspace)
        } detail: {
            DetailView(store: store, workspace: workspace)
                .navigationTitle(windowTitle)
                .navigationSubtitle(windowSubtitle)
                .inspector(isPresented: inspectorBinding) {
                    LaunchInspectorView(store: store, workspace: workspace)
                        .inspectorColumnWidth(min: 260, ideal: Metrics.inspectorIdeal)
                }
        }
        .searchable(text: searchBinding, placement: .toolbar, prompt: Text(workspace.searchPlaceholder))
        .toolbar { RavenToolbar(store: store, workspace: workspace) }
        .sheet(item: sheetBinding) { request in
            sheetContent(request)
        }
        .alert("Remove this provider?", isPresented: removalBinding, presenting: workspace.pendingRemoval) { provider in
            Button("Remove \(provider.name)", role: .destructive) {
                workspace.removePendingProvider()
            }
            Button("Cancel", role: .cancel) { workspace.pendingRemoval = nil }
        } message: { provider in
            Text("Raven forgets \(provider.name)'s base URL and API key, along with its pins and context window overrides.")
        }
        .alert("Couldn't launch", isPresented: launchErrorBinding, presenting: workspace.launchError) { _ in
            Button("OK", role: .cancel) { workspace.launchError = nil }
        } message: { message in
            Text(message)
        }
        .fileImporter(isPresented: workdirBinding,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                store.workdir = url
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var windowTitle: String {
        if store.providers.isEmpty && workspace.destination.isLauncherPage { return "Raven" }
        return workspace.title
    }

    private var windowSubtitle: String {
        if store.providers.isEmpty && workspace.destination.isLauncherPage { return "" }
        return workspace.subtitle
    }

    private var searchBinding: Binding<String> {
        Binding(get: { workspace.search }, set: { workspace.search = $0 })
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { shell.inspectorShown && workspace.destination.isLauncherPage && !store.providers.isEmpty },
            set: { shell.inspectorShown = $0 })
    }

    private var workdirBinding: Binding<Bool> {
        Binding(
            get: { workspace.isChoosingWorkdir },
            set: { workspace.isChoosingWorkdir = $0 })
    }

    private var sheetBinding: Binding<SheetRequest?> {
        Binding(
            get: {
                if let draft = workspace.providerDraft { return .provider(draft) }
                if let draft = workspace.windowDraft { return .contextWindow(draft) }
                if workspace.isShowingScript { return .script }
                return nil
            },
            set: { newValue in
                if newValue == nil {
                    workspace.providerDraft = nil
                    workspace.windowDraft = nil
                    workspace.isShowingScript = false
                }
            })
    }

    @ViewBuilder
    private func sheetContent(_ request: SheetRequest) -> some View {
        switch request {
        case .provider(let draft):
            ProviderSheet(draft: draft, workspace: workspace)
        case .contextWindow(let draft):
            ContextWindowSheet(draft: draft, workspace: workspace)
        case .script:
            LaunchScriptSheet(store: store, workspace: workspace)
        }
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { workspace.pendingRemoval != nil },
            set: { if !$0 { workspace.pendingRemoval = nil } })
    }

    private var launchErrorBinding: Binding<Bool> {
        Binding(
            get: { workspace.launchError != nil },
            set: { if !$0 { workspace.launchError = nil } })
    }
}
