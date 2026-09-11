import Foundation
import Testing
@testable import Raven

struct ModelParsingTests {

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "raven-tests")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ProviderStore.configDirectoryOverride = dir
    }

    @Test func oldConfigShapeStillLoads() throws {
        let old = """
        {
          "providers" : [
            { "id" : "11111111-1111-1111-1111-111111111111",
              "name" : "Test", "baseURL" : "https://proxy.test",
              "apiKey" : "k" }
          ],
          "selectedProviderID" : "11111111-1111-1111-1111-111111111111",
          "selectedClient" : "codex"
        }
        """
        let config = try JSONDecoder().decode(RavenConfig.self, from: Data(old.utf8))
        #expect(config.providers.count == 1)
        #expect(config.providers[0].name == "Test")
        #expect(config.windowOverrides.isEmpty)
        #expect(config.selectedClient == .codex)
        #expect(config.workdir == nil)
    }

    @Test func configRoundTripsWorkdir() throws {
        let config = RavenConfig(providers: [], windowOverrides: [], selectedProviderID: nil,
                                 selectedModelID: nil, selectedClient: .claude, workdir: "/tmp/proj")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(RavenConfig.self, from: data)
        #expect(decoded.workdir == "/tmp/proj")
        #expect(decoded.selectedClient == .claude)
    }

    @Test func parsesProxyStyleModelsResponse() throws {
        let json = """
        {
          "object": "list",
          "data": [
            {
              "id": "deepseek-v4-flash@BAI",
              "object": "model",
              "created": 1788135783,
              "owned_by": "BAI",
              "display_name": "deepseek-v4-flash@BAI",
              "context_length": 200000,
              "context_window": 200000,
              "api_backend": "responses",
              "max_context_length": 200000
            },
            {
              "id": "gpt-5.6-sol@OpenAI",
              "object": "model",
              "owned_by": "openai"
            }
          ]
        }
        """
        let entries = try JSONDecoder().decode(ModelsResponse.self, from: Data(json.utf8)).entries
        #expect(entries.count == 2)
        #expect(entries[0].modelID == "deepseek-v4-flash@BAI")
        #expect(entries[0].ownedBy == "BAI")
        #expect(entries[0].contextWindow == 200_000)
        #expect(entries[1].modelID == "gpt-5.6-sol@OpenAI")
        #expect(entries[1].contextWindow == nil)
    }

    @Test func parsesOpenAIStandardModelsResponse() throws {
        let json = """
        {"object":"list","data":[{"id":"gpt-4o","object":"model","created":1686935002,"owned_by":"system"}]}
        """
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: Data(json.utf8))
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].modelID == "gpt-4o")
        #expect(decoded.entries[0].ownedBy == "system")
    }

    @Test func providerURLNormalization() {
        let provider = Provider(name: "t", baseURL: "https://proxy.test/", apiKey: "k")
        #expect(provider.rootURL == "https://proxy.test")
        #expect(provider.v1URL == "https://proxy.test/v1")
        #expect(provider.modelsURL == "https://proxy.test/v1/models")
        #expect(provider.host == "proxy.test")

        let withV1 = Provider(name: "t", baseURL: "https://api.example.com/v1", apiKey: "k")
        #expect(withV1.rootURL == "https://api.example.com/v1")
        #expect(withV1.v1URL == "https://api.example.com/v1")

        let trailing = Provider(name: "t", baseURL: "https://api.example.com/v1/", apiKey: "k")
        #expect(trailing.v1URL == "https://api.example.com/v1")
    }

    @Test func providerDraftValidation() {
        let empty = ProviderDraft()
        #expect(empty.validated() == nil)
        #expect(empty.validationMessage == "Base URL is required")

        let badScheme = ProviderDraft()
        badScheme.baseURL = "ftp://proxy.test"
        #expect(badScheme.validated() == nil)
        #expect(badScheme.validationMessage == "Base URL must start with http:// or https://")

        let valid = ProviderDraft()
        valid.baseURL = " https://proxy.test/ "
        valid.apiKey = " k "
        let provider = valid.validated()
        #expect(provider?.name == "Provider")
        #expect(provider?.baseURL == "https://proxy.test/")
        #expect(provider?.apiKey == "k")

        let existing = Provider(name: "Old", baseURL: "https://proxy.test", apiKey: "k")
        let edit = ProviderDraft(existing)
        edit.name = "New"
        #expect(edit.isEditing)
        #expect(edit.validated()?.id == existing.id)
        #expect(edit.validated()?.name == "New")
    }

    @Test func windowDraftTokens() {
        let draft = WindowDraft(providerID: UUID(), modelID: "m", current: nil)
        #expect(draft.text == "200000")
        #expect(draft.tokens == 200_000)
        draft.text = " 400000 "
        #expect(draft.tokens == 400_000)
        draft.text = "abc"
        #expect(draft.tokens == nil)
        draft.text = "0"
        #expect(draft.tokens == nil)
    }

    @Test func contextWindowLabels() {
        #expect(ContextWindow.label(200_000) == "200K ctx")
        #expect(ContextWindow.label(1_000_000) == "1M ctx")
        #expect(ContextWindow.label(1_500) == "1500 ctx")
    }

    @Test func shellQuoting() {
        #expect(Launcher.shellQuote("plain") == "'plain'")
        #expect(Launcher.shellQuote("it's") == "'it'\\''s'")
        #expect(Launcher.shellQuote("https://proxy.test") == "'https://proxy.test'")
    }

    @Test func launchScriptUsesWindowOverride() throws {
        let provider = Provider(name: "Test", baseURL: "https://proxy.test", apiKey: "k-1")
        let store = ProviderStore.shared
        store.setWindowOverride(providerID: provider.id,
                                modelID: "some-model",
                                contextWindow: 400_000)
        defer { store.setWindowOverride(providerID: provider.id,
                                        modelID: "some-model",
                                        contextWindow: nil) }
        let script = Launcher.makeScript(
            provider: provider,
            model: "some-model",
            client: .codex,
            workdir: URL(filePath: "/tmp/proj")
        )
        #expect(script.contains("-c model_context_window=400000"))
    }

    @Test func launchScriptClaude() throws {
        let provider = Provider(name: "Test", baseURL: "https://proxy.test", apiKey: "k-1")
        let script = Launcher.makeScript(
            provider: provider,
            model: "deepseek-v4-flash@BAI",
            client: .claude,
            workdir: URL(filePath: "/tmp/proj")
        )
        #expect(script.hasPrefix("#!/usr/bin/env bash\n"))
        #expect(script.contains("cd '/tmp/proj'"))
        #expect(script.contains("export ANTHROPIC_BASE_URL='https://proxy.test'"))
        #expect(script.contains("export ANTHROPIC_AUTH_TOKEN='k-1'"))
        #expect(script.contains("unset ANTHROPIC_API_KEY"))
        #expect(script.contains("exec claude --model 'deepseek-v4-flash@BAI' --disallowedTools 'WebSearch'"))
        #expect(script.contains("export CLAUDE_CODE_MAX_CONTEXT_TOKENS=200000"), "translated model defaults to 200K")
        #expect(script.contains("export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000"))
    }

    @Test func launchScriptCodex() throws {
        let provider = Provider(name: "Test", baseURL: "https://proxy.test", apiKey: "k-1")
        let script = Launcher.makeScript(
            provider: provider,
            model: "deepseek-v4-flash@BAI",
            client: .codex,
            workdir: URL(filePath: "/tmp/proj")
        )
        #expect(script.contains("-c model_providers.raven.base_url='https://proxy.test/v1'"))
        #expect(script.contains("-c model_providers.raven.wire_api=responses"))
        #expect(script.contains("-c model_providers.raven.env_key=RAVEN_API_KEY"))
        #expect(script.contains("-c web_search=disabled"))
        #expect(script.contains("-c model_context_window=200000"))
        #expect(script.contains("exec codex -c model_provider=raven"))
        #expect(script.contains("export RAVEN_API_KEY='k-1'"))
    }

    @Test func launchScriptCodexDoesNotForceWindowForGptModels() throws {
        let provider = Provider(name: "Test", baseURL: "https://proxy.test", apiKey: "k-1")
        let script = Launcher.makeScript(
            provider: provider,
            model: "gpt-5.6-sol",
            client: .codex,
            workdir: URL(filePath: "/tmp/proj")
        )
        #expect(!script.contains("-c model_context_window="),
                "Codex knows gpt-5.6-sol's real window; Raven should not cap it")
        #expect(script.contains("exec codex -c model_provider=raven "))
        #expect(script.contains("-m 'gpt-5.6-sol'"))
    }

    @Test func launchScriptCodexForcesWindowForGptWithOverride() throws {
        let provider = Provider(name: "Test", baseURL: "https://proxy.test", apiKey: "k-1")
        let store = ProviderStore.shared
        store.setWindowOverride(providerID: provider.id,
                                modelID: "gpt-5.6-sol",
                                contextWindow: 300_000)
        defer { store.setWindowOverride(providerID: provider.id,
                                        modelID: "gpt-5.6-sol",
                                        contextWindow: nil) }
        let script = Launcher.makeScript(
            provider: provider,
            model: "gpt-5.6-sol",
            client: .codex,
            workdir: URL(filePath: "/tmp/proj")
        )
        #expect(script.contains("-c model_context_window=300000"),
                "an explicit user override still wins for gpt models")
    }
}
