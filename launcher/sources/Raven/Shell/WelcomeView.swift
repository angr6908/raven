import SwiftUI

struct WelcomeView: View {
    let workspace: Workspace

    var body: some View {
        EmptyState(symbol: "square.stack.3d.up.fill",
                   title: "Welcome to Raven",
                   message: "Add an OpenAI-compatible provider and Raven lists its models here, ready to launch into Claude Code or Codex.") {
            HStack {
                Button("Add Provider…") { workspace.addProvider() }
                    .buttonStyle(.glassProminent)
                Button("Add Local Proxy") { workspace.addLocalProxy() }
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
