import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: Space.xl) {
            Image(systemName: "bird.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(Space.xl)
                .glassEffect(.regular, in: .circle)

            VStack(spacing: Space.sm) {
                Text("Welcome to Raven").font(.largeTitle.weight(.semibold))
                Text("Connect an OpenAI-compatible provider and every model it serves shows up here, one keystroke from Claude Code or Codex.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            GlassEffectContainer(spacing: Space.md) {
                HStack(spacing: Space.md) {
                    Button("Add Provider…", systemImage: "plus") { app.addProvider() }
                        .buttonStyle(.glassProminent)
                    Button("Use Local Proxy", systemImage: "house") { app.addLocalProxy() }
                        .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
