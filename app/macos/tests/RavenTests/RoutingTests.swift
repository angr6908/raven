import Foundation
import Testing
@testable import Raven

struct RoutingTableTests {
    private let levels = PanelLogic.fallbackEffortLevels

    private func model(_ name: String, alias: String? = nil, levels: [String]? = nil) -> ProviderModelDef {
        var def = ProviderModelDef(name: name, alias: alias)
        if let levels { def.thinking = ThinkingShape(levels: levels) }
        return def
    }

    private func provider(_ name: String, kind: String? = "openai", disabled: Bool? = nil,
                          base: String = "https://api.example.com/v1", key: String = "k",
                          models: [ProviderModelDef]) -> ProviderEntry {
        ProviderEntry(name: name, disabled: disabled, kind: kind, baseUrl: base,
                      apiKeyEntries: key.isEmpty ? [] : [ApiKeyEntry(apiKey: key)], models: models)
    }

    @Test func resolvesByAliasOrUpstreamNameTopProviderFirst() throws {
        let providers = [
            provider("BAI", models: [model("glm-4.6", alias: "glm-4.6@BAI")]),
            provider("OR", models: [model("glm-4.6", alias: "glm-4.6@OR"), model("kimi-k2")]),
        ]
        let byAlias = try #require(RoutingTable.resolve("glm-4.6@OR", in: providers, levels: levels))
        #expect(byAlias.source == "OR")
        #expect(byAlias.upstream == "glm-4.6")
        #expect(byAlias.effort == nil)

        let byName = try #require(RoutingTable.resolve("glm-4.6", in: providers, levels: levels))
        #expect(byName.source == "BAI")

        #expect(RoutingTable.resolve("kimi-k2", in: providers, levels: levels)?.model == 1)
        #expect(RoutingTable.resolve("missing", in: providers, levels: levels) == nil)
        #expect(RoutingTable.resolve("", in: providers, levels: levels) == nil)
    }

    @Test func trailingEffortSuffixSplitsOnlyWhenTheModelAllowsIt() throws {
        let providers = [
            provider("BAI", models: [model("glm-4.6", alias: "glm-4.6@BAI", levels: ["low", "high"]),
                                     model("kimi-k2", alias: "kimi@BAI")]),
        ]
        let curated = try #require(RoutingTable.resolve("glm-4.6@BAI@high", in: providers, levels: levels))
        #expect(curated.effort == "high")
        #expect(curated.clientID == "glm-4.6@BAI")

        #expect(RoutingTable.resolve("glm-4.6@BAI@max", in: providers, levels: levels) == nil)

        let open = try #require(RoutingTable.resolve("kimi@BAI@XHIGH", in: providers, levels: levels))
        #expect(open.effort == "xhigh")
        #expect(open.upstream == "kimi-k2")

        #expect(RoutingTable.resolve("nobody@high", in: providers, levels: levels) == nil)
        #expect(RoutingTable.resolve("@high", in: providers, levels: levels) == nil)
    }

    @Test func splitEffortNeedsKnownLevelAndBase() {
        #expect(RoutingTable.splitEffort("m@low", levels: levels)?.effort == "low")
        #expect(RoutingTable.splitEffort("m@BAI", levels: levels) == nil)
        #expect(RoutingTable.splitEffort("@low", levels: levels) == nil)
        #expect(RoutingTable.splitEffort("plain", levels: levels) == nil)
    }

    @Test func statusesExplainWhoAnswers() {
        let providers = [
            provider("first", models: [model("glm-4.6", alias: "glm")]),
            provider("second", models: [model("glm-4.6", alias: "glm"), model("deepseek"), model("deepseek"), model("")]),
            provider("off", disabled: true, models: [model("qwen")]),
        ]
        let rows = RoutingTable.rows(providers)
        #expect(rows.map(\.status) == [
            .active,
            .shadowed("first"),
            .active,
            .duplicate,
            .incomplete,
            .hidden,
        ])
        #expect(rows[1].clientID == "glm")
        #expect(rows.filter(\.status.isProblem).count == 3)
    }

    @Test func managedChannelsUseTheirTitles() {
        let providers = [
            PanelLogic.blankProviderEntry(kind: "workbuddy", name: "workbuddy"),
            provider("x", models: []),
        ]
        #expect(RoutingTable.sourceName(providers[0]) == "WorkBuddy")
        #expect(RoutingTable.sourceName(provider("  ", models: [])) == "Untitled")
        #expect(RoutingTable.issues(at: 0, in: providers).isEmpty)
    }

    @Test func issuesFlagBrokenEndpoints() {
        let providers = [
            provider("B.AI", base: "https:/api.b.ai/v1", models: []),
            provider("", base: "", key: "", models: []),
            provider("dup", models: []),
            provider("DUP", base: "http://127.0.0.1:8080/v1", models: []),
        ]
        #expect(RoutingTable.issues(at: 0, in: providers) == [.invalidURL])
        #expect(RoutingTable.issues(at: 1, in: providers) == [.missingName, .missingURL, .missingKey])
        #expect(RoutingTable.issues(at: 2, in: providers) == [.duplicateName])
        #expect(RoutingTable.issues(at: 3, in: providers) == [.duplicateName])
        #expect(RoutingTable.issues(at: 9, in: providers).isEmpty)
        #expect(ProviderIssue.invalidURL.blocking)
        #expect(!ProviderIssue.missingKey.blocking)
    }

    @Test func endpointFollowsProtocol() {
        var entry = provider("p", base: "https://api.example.com/v1/", models: [])
        #expect(RoutingTable.endpoint(entry) == "https://api.example.com/v1/chat/completions")
        entry.kind = "responses"
        #expect(RoutingTable.endpoint(entry) == "https://api.example.com/v1/responses")
        entry.baseUrl = " "
        #expect(RoutingTable.endpoint(entry) == nil)
    }

    @Test func reorderKeepsUnmovableSlotsInPlace() {
        let items = ["a", "W", "b", "c", "G"]
        let movable: (String) -> Bool = { $0 == $0.lowercased() }
        #expect(RoutingTable.reorder(items, where: movable, from: [2], to: 0) == ["c", "W", "a", "b", "G"])
        #expect(RoutingTable.reorder(items, where: movable, from: [0], to: 3) == ["b", "W", "c", "a", "G"])
        #expect(RoutingTable.reorder(items, where: movable, from: [0, 1], to: 3) == ["c", "W", "a", "b", "G"])
        #expect(RoutingTable.reorder(items, where: movable, from: [1], to: 1) == items)
    }

    @Test func effortSummaryCompactsRanges() {
        #expect(RoutingTable.effortSummary([], order: levels) == "All")
        #expect(RoutingTable.effortSummary(["high"], order: levels) == "high")
        #expect(RoutingTable.effortSummary(["low", "medium", "high"], order: levels) == "low–high")
        #expect(RoutingTable.effortSummary(["low", "high", "max"], order: levels) == "low, high, max")
        #expect(RoutingTable.effortSummary(["low", "turbo"], order: levels) == "low, turbo")
        #expect(RoutingTable.ordered(["max", "turbo", "low"], order: levels) == ["low", "max", "turbo"])
    }

    @Test func copyNameAvoidsCollisions() {
        #expect(RoutingTable.copyName("or", existing: ["or"]) == "or-copy")
        #expect(RoutingTable.copyName("or", existing: ["or", "OR-copy"]) == "or-copy-2")
        #expect(RoutingTable.copyName("", existing: []) == "provider-copy")
    }
}

struct AutoSaveTests {
    @Test func flushRunsOnlyTheLatestPendingSave() async {
        let saver = AutoSaveScheduler()
        var runs: [Int] = []
        saver.schedule { runs.append(1) }
        saver.schedule { runs.append(2) }
        #expect(saver.status == .saving)
        let ok = await saver.flush()
        #expect(ok)
        #expect(runs == [2])
        #expect(saver.status == .saved)
        #expect(await saver.flush())
        #expect(runs == [2])
    }

    @Test func flushReportsFailure() async {
        let saver = AutoSaveScheduler()
        saver.schedule { throw PanelError.api(code: nil, message: "disk full") }
        let ok = await saver.flush()
        #expect(!ok)
        #expect(saver.status == .failed("disk full"))
    }
}
