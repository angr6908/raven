import SwiftUI

struct PanelPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                content
            }
            .frame(maxWidth: Metrics.maxPanelWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Metrics.contentMargin)
            .padding(.top, Metrics.spacing4)
            .padding(.bottom, Metrics.spacing6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable {
            UsageStore.shared.start()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
