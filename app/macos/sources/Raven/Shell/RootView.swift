import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: Layout.sidebarMin, ideal: Layout.sidebarIdeal,
                                                max: Layout.sidebarMax)
        } detail: {
            DetailRouter()
        }
        .frame(minWidth: 1000, minHeight: 560)
        .sheet(item: $app.sheet) { sheet in
            SheetHost(sheet: sheet)
        }
        .alert("Remove this provider?", item: $app.removal) { provider in
            Button("Remove \(provider.name)", role: .destructive) { app.removePending() }
            Button("Cancel", role: .cancel) {}
        } message: { provider in
            Text("Raven forgets \(provider.name)'s base URL and API key, along with its pins and context window overrides.")
        }
        .alert("Couldn't launch", item: $app.launchError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .fileImporter(isPresented: $app.isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { app.setWorkdir(url) }
        }
    }
}

private struct DetailRouter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.page {
        case .models, .pinned, .provider: ModelsPage()
        case .recents: RecentsPage()
        case .overview: OverviewPage()
        case .usage: UsagePage()
        case .accounts: AccountsPage()
        case .routing: RoutingPage()
        case .pricing: PricingPage()
        }
    }
}

private struct SheetHost: View {
    let sheet: Sheet

    var body: some View {
        switch sheet {
        case .provider(let draft): ProviderSheet(draft: draft)
        case .script: ScriptSheet()
        case .quickLaunch: QuickLaunchSheet()
        case .addAccount(let kind): AddAccountSheet(kind: kind)
        }
    }
}
