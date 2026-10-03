import AppKit

@MainActor
final class WelcomeViewController: NSViewController {
    private let workspace = RavenRuntime.shared.workspace

    override func loadView() {
        view = NSView()
        let content = UnavailableView(symbol: "square.stack.3d.up.fill",
                                      title: "Welcome to Raven",
                                      description: "Add an OpenAI-compatible provider and Raven lists its models here, ready to launch into Claude Code or Codex.",
                                      actions: [
                                          AppKitTheme.glassButton(title: "Add Provider…",
                                                                   symbol: "plus",
                                                                   prominent: true,
                                                                   action: #selector(addProvider),
                                                                   target: self),
                                          AppKitTheme.glassButton(title: "Add Local Proxy",
                                                                   symbol: "localhost",
                                                                   prominent: false,
                                                                   action: #selector(addLocalProxy),
                                                                   target: self),
                                      ])
        content.translatesAutoresizingMaskIntoConstraints = false
        let hero = NSView()
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: hero.topAnchor),
            content.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: hero.bottomAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        view.addSubview(hero)
        NSLayoutConstraint.activate([
            hero.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hero.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            hero.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            hero.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            hero.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor),
            hero.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])
    }

    @objc private func addProvider() {
        workspace.addProvider()
    }

    @objc private func addLocalProxy() {
        workspace.addLocalProxy()
    }
}
