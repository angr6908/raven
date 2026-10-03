import SwiftUI

struct DetailView: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if workspace.destination.isLauncherPage && store.providers.isEmpty {
            WelcomeView(workspace: workspace)
        } else {
            switch workspace.destination {
            case .library, .pinned, .provider:
                ModelListView(store: store, workspace: workspace)
            case .recents:
                RecentsView(store: store, workspace: workspace)
            case .overview:
                OverviewView()
            case .usage:
                UsageView()
            case .accounts:
                AccountsView()
            case .providersPage:
                ProvidersPanelView()
            case .pricing:
                PricingView()
            }
        }
    }
}
