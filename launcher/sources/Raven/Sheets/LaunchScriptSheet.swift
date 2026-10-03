import SwiftUI

struct LaunchScriptSheet: View {
    let store: ProviderStore
    let workspace: Workspace

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing3) {
            ScrollView([.vertical, .horizontal]) {
                Text(store.launchScript() ?? "")
                    .font(RavenFont.mono(12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.spacing2)
            }
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))

            HStack {
                Button {
                    workspace.copyScript()
                } label: {
                    Label(workspace.didCopyScript ? "Copied" : "Copy",
                          systemImage: workspace.didCopyScript ? "checkmark" : "document.on.document")
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Metrics.spacing4)
        .frame(width: 620, height: 460)
    }
}
