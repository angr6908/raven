import AppKit
import Foundation

enum LaunchError: LocalizedError {
    case notLaunched(String)

    var errorDescription: String? {
        switch self {
        case .notLaunched(let detail): "Terminal launch failed: \(detail)"
        }
    }
}

enum Launcher {
    static let slotCapabilities = "effort,max_effort,xhigh_effort,adaptive_thinking,context_management"

    static func makeScript(provider: Provider,
                           model: String,
                           client: ProviderKind,
                           workdir: URL) -> String {
        let root = shellQuote(provider.rootURL)
        let key = shellQuote(provider.apiKey)
        let modelQ = shellQuote(model)

        var lines: [String] = []
        lines.append("#!/usr/bin/env bash")
        lines.append("set -euo pipefail")
        lines.append("case \":$PATH:\" in")
        lines.append("  *\":$HOME/.bun/bin:\"*) ;;")
        lines.append("  *) [ -d \"$HOME/.bun/bin\" ] && PATH=\"$HOME/.bun/bin:$PATH\" ;;")
        lines.append("esac")
        lines.append("cd \(shellQuote(workdir.path(percentEncoded: false)))")
        lines.append("")

        switch client {
        case .claude:
            appendClaudeLines(&lines, provider: provider, model: model,
                              root: root, key: key, modelQ: modelQ)
        case .codex:
            appendCodexLines(&lines, provider: provider, model: model,
                             root: root, key: key, modelQ: modelQ)
        }

        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendClaudeLines(_ lines: inout [String],
                                          provider: Provider,
                                          model: String,
                                          root: String,
                                          key: String,
                                          modelQ: String) {
        let isClaudeSlug = model.hasPrefix("claude-")
        let configured = ProviderStore.shared.effectiveWindow(providerID: provider.id, modelID: model)
        let window = configured ?? ContextWindow.fallback

        lines.append("unset ANTHROPIC_API_KEY")
        lines.append("export ANTHROPIC_BASE_URL=\(root)")
        lines.append("export ANTHROPIC_AUTH_TOKEN=\(key)")
        lines.append("")

        lines.append("export CLAUDE_CODE_SUBAGENT_MODEL=\(modelQ)")
        lines.append("export CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1")
        for slot in ["OPUS", "SONNET", "HAIKU"] {
            lines.append("export ANTHROPIC_DEFAULT_\(slot)_MODEL=\(modelQ)")
            lines.append("export ANTHROPIC_DEFAULT_\(slot)_MODEL_SUPPORTED_CAPABILITIES=\(shellQuote(slotCapabilities))")
        }

        if configured != nil || !isClaudeSlug {
            lines.append("export CLAUDE_CODE_MAX_CONTEXT_TOKENS=\(window)")
        }
        if window <= 1_000_000 {
            lines.append("export CLAUDE_CODE_AUTO_COMPACT_WINDOW=\(window)")
        }
        lines.append("export CLAUDE_CODE_ATTRIBUTION_HEADER=0")

        var args = ["--model", modelQ]
        if !isClaudeSlug {
            args += ["--disallowedTools", shellQuote("WebSearch")]
        }
        lines.append("exec claude \(args.joined(separator: " "))")
    }

    private static func appendCodexLines(_ lines: inout [String],
                                         provider: Provider,
                                         model: String,
                                         root: String,
                                         key: String,
                                         modelQ: String) {
        let v1 = shellQuote(provider.v1URL)
        let configured = ProviderStore.shared.effectiveWindow(providerID: provider.id, modelID: model)
        let isGptSlug = model.hasPrefix("gpt-")

        lines.append("export RAVEN_API_KEY=\(key)")
        lines.append("rm -f \"$HOME/.codex/models_cache.json\"")
        var args: [String] = [
            "-c model_provider=raven",
            "-c model_providers.raven.name=Raven",
            "-c model_providers.raven.base_url=\(v1)",
            "-c model_providers.raven.wire_api=responses",
            "-c model_providers.raven.env_key=RAVEN_API_KEY",
            "-c model_providers.raven.request_max_retries=20",
            "-c model_providers.raven.stream_max_retries=20",
            "-c web_search=disabled",
            "-m \(modelQ)",
        ]
        if configured != nil || !isGptSlug {
            args.append("-c model_context_window=\(configured ?? ContextWindow.fallback)")
        }
        lines.append("exec codex \(args.joined(separator: " "))")
    }

    static func launch(provider: Provider,
                       model: String,
                       client: ProviderKind,
                       workdir: URL) async throws {
        let script = makeScript(provider: provider, model: model,
                                client: client, workdir: workdir)
        let scriptURL = ProviderStore.configDirectory.appending(path: "launch.sh")
        do {
            try ProviderStore.ensureConfigDirectory()
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: scriptURL.path(percentEncoded: false))
        } catch {
            throw LaunchError.notLaunched(error.localizedDescription)
        }

        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw LaunchError.notLaunched("Terminal was not found")
        }
        do {
            _ = try await NSWorkspace.shared.open([scriptURL],
                                                  withApplicationAt: terminal,
                                                  configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw LaunchError.notLaunched(error.localizedDescription)
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
