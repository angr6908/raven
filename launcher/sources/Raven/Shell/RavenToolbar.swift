import SwiftUI

struct HealthPill: View {
    let store: ProviderStore

    var body: some View {
        let state = Self.state(live: UsageStore.shared.isLive,
                               up: UsageStore.shared.isProxyUp,
                               dropped: UsageStore.shared.droppedRecords)
        Text(state.label)
            .font(RavenFont.numeric(10, weight: .medium))
            .foregroundStyle(state.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(state.color.opacity(0.14), in: Capsule())
            .help(state.help)
    }

    static func state(live: Bool, up: Bool, dropped: Int) -> (label: String, color: Color, help: String) {
        if live && dropped > 0 {
            return ("proxy · stale", .yellow, "Live feed degraded — counts reflect the last full snapshot")
        }
        if live { return ("proxy · live", .green, "proxy ok") }
        if up { return ("proxy", .secondary, "proxy ok") }
        return ("offline", .red, "proxy unreachable")
    }
}

struct RavenToolbar: ToolbarContent {
    let store: ProviderStore
    let workspace: Workspace

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                workspace.refreshVisible()
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(store.isRefreshing)
            .help("Refresh this view (⌘R)")
        }

        ToolbarItem(placement: .status) {
            HealthPill(store: store)
        }
    }
}
