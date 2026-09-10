import Foundation
import Testing
@testable import Raven

struct ModelParsingTests {

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raven-tests")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ProviderStore.configDirectoryOverride = dir
    }

    @Test func testOldConfigShapeStillLoads() throws {
        let old = """
        {
          "providers" : [
            { "id" : "11111111-1111-1111-1111-111111111111",
              "name" : "Test", "baseURL" : "https://proxy.test",
              "apiKey" : "k" }
          ],
          "selectedProviderID" : "11111111-1111-1111-1111-111111111111"
        }
        """
        let config = try JSONDecoder().decode(RavenConfig.self, from: Data(old.utf8))
        #expect(config.providers.count == 1)
        #expect(config.providers[0].name == "Test")
        #expect(config.windowOverrides.isEmpty)
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
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: Data(json.utf8))
        let entries = decoded.entries
        #expect(entries.count == 2)
        #expect(entries[0].modelID == "deepseek-v4-flash@BAI")
        #expect(entries[0].ownedBy == "BAI")
        #expect(entries[0].contextWindow == 200_000)
        #expect(entries[1].modelID == "gpt-5.6-sol@OpenAI")
        #expect(entries[1].contextWindow == nil)
    }

    @Test func testParsesOpenAIStandardModelsResponse() throws {
        let json = """
        {"object":"list","data":[{"id":"gpt-4o","object":"model","created":1686935002,"owned_by":"system"}]}
        """
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: Data(json.utf8))
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].modelID == "gpt-4o")
        #expect(decoded.entries[0].ownedBy == "system")
    }

    @Test func testProviderURLNormalization() {
        let provider = Provider(name: "t", baseURL: "https://proxy.test/", apiKey: "k")
        #expect(provider.rootURL == "https://proxy.test")
        #expect(provider.v1URL == "https://proxy.test/v1")

        let withV1 = Provider(name: "t", baseURL: "https://api.example.com/v1", apiKey: "k")
        #expect(withV1.rootURL == "https://api.example.com/v1")
        #expect(withV1.v1URL == "https://api.example.com/v1")

        let trailing = Provider(name: "t", baseURL: "https://api.example.com/v1/", apiKey: "k")
        #expect(trailing.v1URL == "https://api.example.com/v1")
    }

    @Test func testShellQuoting() {
        #expect(Launcher.shellQuote("plain") == "'plain'")
        #expect(Launcher.shellQuote("it's") == "'it'\\''s'")
        #expect(Launcher.shellQuote("https://proxy.test") == "'https://proxy.test'")
    }

    @MainActor
    @Test func testLaunchScriptUsesWindowOverride() throws {
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
            workdir: URL(fileURLWithPath: "/tmp/proj")
        )
        #expect(script.contains("-c model_context_window=400000"))
    }

    @MainActor
    @Test func testLaunchScriptClaude() throws {
        let provider = Provider(name: "Test", baseURL: "https://proxy.test", apiKey: "k-1")
        let script = Launcher.makeScript(
            provider: provider,
            model: "deepseek-v4-flash@BAI",
            client: .claude,
            workdir: URL(fileURLWithPath: "/tmp/proj")
        )
        #expect(script.contains("export ANTHROPIC_BASE_URL='https://proxy.test'"))
        #expect(script.contains("export ANTHROPIC_AUTH_TOKEN='k-1'"))
        #expect(script.contains("unset ANTHROPIC_API_KEY"))
        #expect(script.contains("exec claude --model 'deepseek-v4-flash@BAI' --disallowedTools 'WebSearch'"))
        #expect(script.contains("export CLAUDE_CODE_MAX_CONTEXT_TOKENS=200000"), "translated model defaults to 200K")
        #expect(script.contains("export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000"))
    }

    @MainActor
    @Test func testLaunchScriptCodex() throws {
        let provider = Provider(name: "Test", baseURL: "https://proxy.test", apiKey: "k-1")
        let script = Launcher.makeScript(
            provider: provider,
            model: "deepseek-v4-flash@BAI",
            client: .codex,
            workdir: URL(fileURLWithPath: "/tmp/proj")
        )
        #expect(script.contains("-c model_providers.raven.base_url='https://proxy.test/v1'"))
        #expect(script.contains("-c model_providers.raven.wire_api=responses"))
        #expect(script.contains("-c model_providers.raven.env_key=RAVEN_API_KEY"))
        #expect(script.contains("-c web_search=disabled"))
        #expect(script.contains("-c model_context_window=200000"))
        #expect(script.contains("exec codex -c model_provider=raven"))
        #expect(script.contains("export RAVEN_API_KEY='k-1'"))
    }

    @MainActor
    @Test func testLaunchScriptCodexDoesNotForceWindowForGptModels() throws {
        let provider = Provider(name: "Test", baseURL: "https://proxy.test", apiKey: "k-1")
        let script = Launcher.makeScript(
            provider: provider,
            model: "gpt-5.6-sol",
            client: .codex,
            workdir: URL(fileURLWithPath: "/tmp/proj")
        )
        #expect(!script.contains("-c model_context_window="),
                "Codex knows gpt-5.6-sol's real window; Raven should not cap it")
        #expect(script.contains("exec codex -c model_provider=raven "))
        #expect(script.contains("-m 'gpt-5.6-sol'"))
    }

    @MainActor
    @Test func testLaunchScriptCodexForcesWindowForGptWithOverride() throws {
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
            workdir: URL(fileURLWithPath: "/tmp/proj")
        )
        #expect(script.contains("-c model_context_window=300000"),
                "an explicit user override still wins for gpt models")
    }
}
