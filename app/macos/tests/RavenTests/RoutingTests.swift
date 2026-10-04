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
