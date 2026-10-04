import Foundation
import Testing
@testable import Raven

private let usageFixture = """
{"object":"list","data":[{"id":"a866d626-8611-4c6d-a5cf-6f45d178345f","timestamp":"2026-10-01T14:33:08Z","account":"skhskshsksjjdhdhska196@gmail.com","model":"Qwen3.8-Flash@WorkBuddy","upstream_model":"Qwen/Qwen3.8-Flash","stream":true,"status":200,"input_tokens":160923,"output_tokens":164,"cached_tokens":159744,"total_tokens":161087,"cache_read_rate":0.9926735146622919,"latency_ms":6056,"ttft_ms":4003,"reasoning_effort":"xhigh","finish_reason":"tool_calls","cost_usd":0.0028098339999999998,"provider":"workbuddy","alias":"Qwen3.8-Flash@WorkBuddy","request_id":"a866d626-8611-4c6d-a5cf-6f45d178345f","token_breakdown":{"input":{"total_tokens":160923,"cache_read_tokens":159744,"cache_write_tokens":0},"output":{"total_tokens":164}}}]}
"""

private let usageMinimal = """
{"id":"r1","timestamp":"2026-01-01T00:00:00Z","account":"a","model":"m","status":500,"error":"boom"}
"""

struct PanelDecodeTests {
    @Test func usageListFullShape() throws {
        let response = try PanelJSON.decoder.decode(UsageListResponse.self, from: Data(usageFixture.utf8))
        let record = try #require(response.data.first)
        #expect(record.model == "Qwen3.8-Flash@WorkBuddy")
        #expect(record.alias == "Qwen3.8-Flash@WorkBuddy")
        #expect(record.displayKey == "Qwen3.8-Flash@WorkBuddy")
        #expect(record.inputTokens == 160_923)
        #expect(record.totalTokens == 161_087)
        #expect(record.costUsd > 0.0028 && record.costUsd < 0.0029)
        #expect(record.reasoningEffort == "xhigh")
        #expect(record.tokenBreakdown?.input.cacheReadTokens == 159_744)
        #expect(record.tokenBreakdown?.output.totalTokens == 164)
        #expect(record.requestId == "a866d626-8611-4c6d-a5cf-6f45d178345f")
    }

    @Test func usageMinimalDefaults() throws {
        let record = try PanelJSON.decoder.decode(UsageRecord.self, from: Data(usageMinimal.utf8))
        #expect(record.status == 500)
        #expect(record.error == "boom")
        #expect(record.inputTokens == 0)
        #expect(record.latencyMs == 0)
        #expect(record.costUsd == 0)
        #expect(record.tokenBreakdown == nil)
        #expect(record.displayKey == "m")
    }

    @Test func healthShape() throws {
        let fixture = """
        {"status":"ok","detail":"","version":"1.0.0","accounts":4,"pools":{"workbuddy":3,"antigravity":1}}
        """
        let health = try PanelJSON.decoder.decode(HealthResponse.self, from: Data(fixture.utf8))
        #expect(health.status == "ok")
    }

    @Test func errorEnvelopeDecodes() throws {
        let fixture = """
        {"error":{"message":"no such account","type":"invalid_request","code":"not_found"}}
        """
        let record = try PanelJSON.decoder.decode(PanelDecodeTests.EnvelopeProbe.self, from: Data(fixture.utf8))
        #expect(record.error.message == "no such account")
        #expect(record.error.code == "not_found")
    }

    private nonisolated struct EnvelopeProbe: Decodable {
        nonisolated struct Body: Decodable {
            var message: String
            var code: String?
        }
        var error: Body
    }

    @Test func pricesWrappedGet() throws {
        let fixture = """
        {"prices":{"gpt-5":{"input":1.25,"output":10,"cached":0.125,"input_peak":2.5,"output_peak":20,"cached_peak":0.25,"peak_windows":[[1,4],[6,10]]}}}
        """
        let prices = try PanelJSON.decoder.decode(PricesResponse.self, from: Data(fixture.utf8))
        let price = try #require(prices.prices["gpt-5"])
        #expect(price.input == 1.25)
        #expect(price.outputPeak == 20)
        #expect(price.peakWindows == [[1, 4], [6, 10]])
    }
}

struct ProviderRoundTripTests {
    @Test func unknownKeysSurviveRoundTrip() throws {
        let fixture = """
        [{"name":"Experiential Labs","kind":"openai","base-url":"https://x.test/v1","disabled":false,"project":"p","unknown-top":{"nested":[1,2.5,"s",true,null]},"api-key-entries":[{"api-key":"k1","proxy-url":"","mystery":42}],"models":[{"name":"glm-4.6","alias":"","display-name":"GLM 4.6","max-context-length":202752,"vendor-extension":{"a":true},"thinking":{"levels":["low","high"]}}]}]
        """
        let decoded = try PanelJSON.decoder.decode([ProviderEntry].self, from: Data(fixture.utf8))
        let entry = try #require(decoded.first)
        #expect(entry.name == "Experiential Labs")
        #expect(entry.baseUrl == "https://x.test/v1")
        #expect(entry.usableKind == "openai")
        #expect(entry.extras["unknown-top"] != nil)
        let key = try #require(entry.apiKeyEntries.first)
        #expect(key.extras["mystery"] == .number(42))
        let model = try #require(entry.models.first)
        #expect(model.alias == nil)
        #expect(model.extras["vendor-extension"] != nil)
        #expect(key.proxyUrl == nil)

        let reencoded = try PanelJSON.encoder.encode(decoded)
        let text = String(decoding: reencoded, as: UTF8.self)
        #expect(text.contains("vendor-extension"))
        #expect(text.contains("mystery"))
        #expect(text.contains("\"nested\": [1,2.5,\"s\",true,null]") || text.contains("unknown-top"))
        #expect(!text.contains("\"alias\":\"\""))
        #expect(!text.contains("\"proxy-url\":\"\""))

        let decodedAgain = try PanelJSON.decoder.decode([ProviderEntry].self, from: reencoded)
        #expect(decodedAgain == decoded)
    }

    @Test func managedKindClassification() throws {
        #expect(ProviderEntry(name: "wb", kind: "workbuddy").isManaged)
        #expect(!ProviderEntry(name: "cc", kind: "openai").isManaged)
        #expect(!ProviderEntry(name: "cc", kind: nil).isManaged)
    }
}

struct AggregationTests {
    private nonisolated func record(id: String, model: String, alias: String? = nil,
                                    status: Int, input: Int, output: Int, cached: Int,
                                    cost: Double, latency: Int, ttft: Int,
                                    timestamp: String = "2026-10-01T10:15:00Z") throws -> UsageRecord {
        let aliasPart = alias.map { ",\"alias\":\"\($0)\"" } ?? ""
        let json = """
        {"id":"\(id)","timestamp":"\(timestamp)","account":"a","model":"\(model)","status":\(status),"input_tokens":\(input),"output_tokens":\(output),"cached_tokens":\(cached),"total_tokens":\(input + output),"latency_ms":\(latency),"ttft_ms":\(ttft),"cost_usd":\(cost),"stream":true,"cache_read_rate":0\(aliasPart)}
        """
        return try PanelJSON.decoder.decode(UsageRecord.self, from: Data(json.utf8))
    }

    @Test func totalsAndBreakdownPreference() throws {
        let withBreakdown = """
        {"id":"b1","timestamp":"2026-10-01T11:00:00Z","account":"a","model":"m","status":200,"input_tokens":100,"output_tokens":10,"cached_tokens":5,"total_tokens":110,"cache_read_rate":0,"latency_ms":1000,"ttft_ms":500,"cost_usd":0.01,"token_breakdown":{"input":{"total_tokens":1000,"cache_read_tokens":500,"cache_write_tokens":10},"output":{"total_tokens":20}}}
        """
        let record = try PanelJSON.decoder.decode(UsageRecord.self, from: Data(withBreakdown.utf8))
        #expect(PanelAggregation.inputTotal(record) == 1000)
        #expect(PanelAggregation.outputTotal(record) == 20)
        #expect(PanelAggregation.cacheRead(record) == 500)

        let totals = PanelAggregation.totals([record])
        #expect(totals.input == 1000)
        #expect(totals.requests == 1)
        #expect(totals.ttftCount == 1)
        #expect(totals.cacheRate == 0.5)
    }

    @Test func byModelMergesAndSorts() throws {
        let a = try record(id: "1", model: "m1", alias: "A", status: 200,
                           input: 100, output: 10, cached: 0, cost: 0.001, latency: 2000, ttft: 900)
        let b = try record(id: "2", model: "m2", status: 500,
                           input: 50, output: 0, cached: 0, cost: 0, latency: 100, ttft: 0)
        let c = try record(id: "3", model: "m1", alias: "A", status: 200,
                           input: 300, output: 30, cached: 100, cost: 0.002, latency: 3000, ttft: 0)
        let agg = PanelAggregation.byModel([a, b, c])
        #expect(agg.count == 2)
        #expect(agg[0].model == "A")
        #expect(agg[0].requests == 2)
        #expect(agg[0].cached == 100)
        #expect(agg[1].errors == 1)
        #expect(agg[1].ok == 0)
    }

    @Test func hourlyBucketsByUTC() throws {
        let early = try record(id: "1", model: "m", status: 200, input: 10, output: 1, cached: 0,
                               cost: 0.1, latency: 100, ttft: 0, timestamp: "2026-10-01T10:15:00Z")
        let late = try record(id: "2", model: "m", status: 200, input: 20, output: 2, cached: 0,
                              cost: 0.2, latency: 100, ttft: 0, timestamp: "2026-10-01T10:45:00Z")
        let nextHour = try record(id: "3", model: "m", status: 200, input: 30, output: 3, cached: 0,
                                  cost: 0.3, latency: 100, ttft: 0, timestamp: "2026-10-01T11:00:00Z")
        let points = PanelAggregation.hourly([early, late, nextHour])
        #expect(points.count == 2)
        #expect(points[0].requests == 2)
        #expect(points[0].inputTokens == 30)
        #expect(points[1].timestamp == "2026-10-01T11:00:00Z")
        #expect(abs(points[0].cost - 0.3) < 0.0001)
    }

    @Test func tpsAndStripVendor() throws {
        #expect(PanelFormats.tps(outputTokens: 100, latencyMs: 2000) == 50)
        #expect(PanelFormats.tps(outputTokens: 100, latencyMs: 0) == nil)
        #expect(PanelAggregation.stripModelVendorAndProvider("Qwen/Qwen3.8-Flash@WorkBuddy") == "Qwen3.8-Flash")
        #expect(PanelAggregation.stripModelVendorAndProvider("glm-4.6") == "glm-4.6")
        #expect(PanelAggregation.stripModelVendorAndProvider("vendor/gpt@") == "gpt")
    }

    @Test func parseTokenCountFormats() {
        #expect(PanelFormats.parseTokenCount("200k") == 200_000)
        #expect(PanelFormats.parseTokenCount("1.5m") == 1_500_000)
        #expect(PanelFormats.parseTokenCount("128,000") == 128_000)
        #expect(PanelFormats.parseTokenCount("1_000") == 1_000)
        #expect(PanelFormats.parseTokenCount("12.5k") == 12_500)
        #expect(PanelFormats.parseTokenCount("0") == nil)
        #expect(PanelFormats.parseTokenCount("-5") == nil)
        #expect(PanelFormats.parseTokenCount("abc") == nil)
    }
}

private let quotaFixture = """
{"accounts":[{"name":"hzhouuz","email":"u@gmail.com","project":null,"error":null,"groups":[{"displayName":"Gemini Models","description":null,"buckets":[{"bucketId":"g5","displayName":"Five Hour Limit Remaining","window":null,"resetTime":null,"remainingFraction":0.55},{"bucketId":"gw","displayName":"Weekly Limit Remaining","window":null,"resetTime":null,"remainingFraction":0.034}]},{"displayName":"Claude and GPT models","description":null,"buckets":[{"bucketId":"c5","displayName":"Five Hour Limit Remaining","window":null,"resetTime":null,"remainingFraction":1.0},{"bucketId":"cm","displayName":"Claude monthly limit remaining","window":null,"resetTime":null,"remainingFraction":0.0}]}]}]}
"""

struct QuotaClassificationTests {
    @Test func percentFormatting() {
        #expect(AccountQuota.quotaPercent(0.55) == "55%")
        #expect(AccountQuota.quotaPercent(0.034) == "3.4%")
        #expect(AccountQuota.quotaPercent(0) == "0%")
        #expect(AccountQuota.quotaPercent(2) == "100%")
        #expect(AccountQuota.quotaPercent(-1) == "0%")
    }

    @Test func resetCountdownFromEpochMs() {
        let now = Date().timeIntervalSince1970
        #expect(AccountQuota.quotaResetShort(fromEpochMs: (now + 2 * 86_400 + 3 * 3_600) * 1_000) == "2d3h")
        #expect(AccountQuota.quotaResetShort(fromEpochMs: (now + 5 * 3_600 + 30 * 60) * 1_000) == "5h30m")
        #expect(AccountQuota.quotaResetShort(fromEpochMs: (now + 40 * 60) * 1_000) == "40m")
        #expect(AccountQuota.quotaResetShort(fromEpochMs: (now - 10) * 1_000) == "now")
        #expect(AccountQuota.quotaResetShort(fromEpochMs: nil) == nil)
    }

    @Test func windowAndGroupClassification() {
        #expect(AccountQuota.quotaWindow("Five Hour Limit Remaining") == "5h")
        #expect(AccountQuota.quotaWindow("five-hour limit remaining") == "5h")
        #expect(AccountQuota.quotaWindow("Weekly limit remaining") == "7d")
        #expect(AccountQuota.quotaWindow("Daily limit remaining") == "daily")
        #expect(AccountQuota.quotaWindow("Month limit remaining") == "monthly")
        #expect(AccountQuota.quotaWindow("limit remaining") == "limit")
        #expect(AccountQuota.quotaGroupName("Gemini Models") == "Gemini")
        #expect(AccountQuota.quotaGroupName("Claude and GPT models") == "Claude")
        #expect(AccountQuota.quotaGroupName("Raw") == "Raw")
    }

    @Test func columnSortOrder() throws {
        let quota = try PanelJSON.decoder.decode(QuotaResponse.self, from: Data(quotaFixture.utf8))
        let columns = AccountQuota.antigravityQuotaColumns(quota.accounts)
        #expect(columns.map(\.header) == ["Gemini 5h", "Claude 5h", "Gemini 7d", "Claude monthly"])
        #expect(columns[0].key == "Gemini Models::5h")
    }

    @Test func antigravityCells() throws {
        let quota = try PanelJSON.decoder.decode(QuotaResponse.self, from: Data(quotaFixture.utf8))
        let columns = AccountQuota.antigravityQuotaColumns(quota.accounts)
        let account = quota.accounts[0]
        #expect(AccountQuota.antigravityCell(quota: account, column: columns[0], first: true)
                    == .value(percent: "55%", reset: nil, title: "Gemini 5h", fraction: 0.55))
        #expect(AccountQuota.antigravityCell(quota: nil, column: columns[0], first: true) == .dash)
        #expect(AccountQuota.antigravityCell(quota: QuotaAccount(name: "x"), column: columns[0], first: true) == .dash)
        #expect(AccountQuota.antigravityCell(quota: QuotaAccount(name: "x", error: "boom"),
                                             column: columns[1], first: false) == .dash)
    }

    @Test func numberFormatting() {
        #expect(AccountQuota.creditsText(12345) == "12,345")
    }
}

struct ModelZoneLogicTests {
    private func model(_ name: String, alias: String? = nil, levels: [String]? = nil) -> ProviderModelDef {
        var def = ProviderModelDef(name: name)
        def.alias = alias
        if let levels { def.thinking = ThinkingShape(levels: levels) }
        return def
    }

    @Test func aliasForStripsVendorPrefix() {
        #expect(PanelLogic.aliasFor(modelName: "glm-4.6", providerName: "WorkBuddy") == "glm-4.6@WorkBuddy")
        #expect(PanelLogic.aliasFor(modelName: "MiniMax/MiniMax-M3", providerName: "cc") == "MiniMax-M3@cc")
        #expect(PanelLogic.aliasFor(modelName: "", providerName: "p") == "@p")
    }

    @Test func withAliasesAlwaysDerivesFromNameAndProvider() {
        let entry = ProviderEntry(name: "cc", models: [model("glm-4.6", alias: "custom"), model("new-one"), model("")])
        let aliased = PanelLogic.withAliases(entry)
        #expect(aliased.models[0].alias == "glm-4.6@cc")
        #expect(aliased.models[1].alias == "new-one@cc")
        #expect(aliased.models[2].alias == nil)

        let renamed = PanelLogic.withAliases(ProviderEntry(name: "renamed", models: aliased.models))
        #expect(renamed.models[0].alias == "glm-4.6@renamed")
    }

    @Test func withAliasesUsesChannelKindWhenUnnamed() {
        let channel = ProviderEntry(name: "", kind: "workbuddy", models: [model("glm-5")])
        #expect(PanelLogic.withAliases(channel).models[0].alias == "glm-5@workbuddy")

        let unnamed = ProviderEntry(name: "  ", kind: "openai", models: [model("glm-5", alias: "mine")])
        #expect(PanelLogic.withAliases(unnamed).models[0].alias == nil)
    }

    @Test func withLevelsCollapsesEmptyThinking() {
        let base = model("m1", levels: ["low", "high"])
        let cleared = PanelLogic.withLevels(base, next: [])
        #expect(cleared.thinking == nil)

        var withMin = base
        withMin.thinking = ThinkingShape(levels: ["low", "high"], min: 1)
        let keptShape = PanelLogic.withLevels(withMin, next: [])
        #expect(keptShape.thinking?.levels == nil)
        #expect(keptShape.thinking?.min == 1)

        let added = PanelLogic.withLevels(model("m2", levels: nil), next: ["minimal"])
        #expect(added.thinking?.levels == ["minimal"])
    }

    @Test func withContextRoundTripsTokenEdits() {
        let set = PanelLogic.withContext(model("m1"), tokens: 200_000)
        #expect(set.maxContextLength == 200_000)
        let cleared = PanelLogic.withContext(set, tokens: PanelFormats.parseTokenCount(""))
        #expect(cleared.maxContextLength == nil)
        let parsed = PanelLogic.withContext(model("m1"), tokens: PanelFormats.parseTokenCount("1.5m"))
        #expect(parsed.maxContextLength == 1_500_000)
    }

    @Test func blankProviderEntryShapes() {
        let entry = PanelLogic.blankProviderEntry(kind: "workbuddy", name: "WorkBuddy")
        #expect(entry.name == "WorkBuddy")
        #expect(entry.kind == "workbuddy")
        #expect(entry.disabled == false)
        #expect(entry.baseUrl == "")
        #expect(entry.apiKeyEntries.isEmpty)
        #expect(entry.models.isEmpty)
    }

    @Test func friendlyLookupErrorRewritesNotFound() {
        #expect(PanelLogic.friendlyLookupError("HTTP 404", what: "context window")
                == "Not found on models.dev — no context window. Check the upstream model name.")
        #expect(PanelLogic.friendlyLookupError("boom", what: "effort") == "boom")
        #expect(PanelLogic.friendlyLookupError("", what: "effort") == "Failed to fetch effort")
    }
}

struct PricingLogicTests {
    private nonisolated func price(_ json: String) throws -> ModelPrice {
        try PanelJSON.decoder.decode(ModelPrice.self, from: Data(json.utf8))
    }

    private nonisolated func lookup(_ json: String) throws -> ModelsDevLookup {
        try PanelJSON.decoder.decode(ModelsDevLookup.self, from: Data(json.utf8))
    }

    @Test func hasPeakChecksPeakValuesAndWindows() throws {
        #expect(!PanelLogic.hasPeak(try price(#"{"input":1,"output":2,"cached":0.5}"#)))
        #expect(!PanelLogic.hasPeak(try price(#"{"input":1,"output":2,"cached":0.5,"input_peak":0,"output_peak":0,"cached_peak":0,"peak_windows":[]}"#)))
        #expect(PanelLogic.hasPeak(try price(#"{"input":1,"output":2,"cached":0.5,"input_peak":0.3,"peak_windows":null}"#)))
        #expect(PanelLogic.hasPeak(try price(#"{"input":1,"output":2,"cached":0.5,"peak_windows":[[1,4]]}"#)))
    }

    @Test func pricedMeansInputOrOutputPositive() throws {
        #expect(PanelLogic.isPriced(try price(#"{"input":0.1,"output":0,"cached":0}"#)))
        #expect(PanelLogic.isPriced(try price(#"{"input":0,"output":9,"cached":0}"#)))
        #expect(!PanelLogic.isPriced(try price(#"{"input":0,"output":0,"cached":5}"#)))
    }

    @Test func peakToggleSeedsMissingPeaksAndWindows() throws {
        var entry = try price(#"{"input":2,"output":8,"cached":0.5,"input_peak":3,"peak_windows":[[5,9]]}"#)
        PanelLogic.applyPeakToggle(&entry, on: true)
        #expect(entry.inputPeak == 3)
        #expect(entry.outputPeak == 16)
        #expect(entry.cachedPeak == 1)
        #expect(entry.peakWindows == [[5, 9]])

        PanelLogic.applyPeakToggle(&entry, on: false)
        #expect(entry.inputPeak == nil)
        #expect(entry.outputPeak == nil)
        #expect(entry.cachedPeak == nil)
        #expect(entry.peakWindows == nil)
        #expect(entry.input == 2)

        var blank = try price(#"{"input":1,"output":4,"cached":0.1}"#)
        PanelLogic.applyPeakToggle(&blank, on: true)
        #expect(blank.inputPeak == 2)
        #expect(blank.outputPeak == 8)
        #expect(blank.cachedPeak == 0.2)
        #expect(blank.peakWindows == [[1, 4], [6, 10]])
    }

    @Test func modelsDevLookupFillsOnlyPresentFields() throws {
        let fetched = try lookup(#"{"source":"minimax","input":1.1,"output":4.4,"efforts":[],"context":1000000,"peak_input":2.2}"#)
        var entry = try price(#"{"input":0,"output":0,"cached":0.25}"#)
        PanelLogic.applyModelsDev(fetched, to: &entry)
        #expect(entry.input == 1.1)
        #expect(entry.output == 4.4)
        #expect(entry.cached == 0.25)
        #expect(entry.inputPeak == 2.2)
        #expect(entry.outputPeak == nil)
        #expect(entry.peakWindows == [[1, 4], [6, 10]])

        var kept = try price(#"{"input":0,"output":0,"cached":0,"input_peak":9,"peak_windows":[[2,3]]}"#)
        PanelLogic.applyModelsDev(fetched, to: &kept)
        #expect(kept.inputPeak == 2.2)
        #expect(kept.peakWindows == [[2, 3]])
    }

    @Test func modelsDevSeedsWindowsOnlyWithPeakInput() throws {
        let fetched = try lookup(#"{"source":"x","input":1,"output":2,"efforts":[],"peak_output":5}"#)
        var entry = try price(#"{"input":0,"output":0,"cached":0}"#)
        PanelLogic.applyModelsDev(fetched, to: &entry)
        #expect(entry.outputPeak == 5)
        #expect(entry.peakWindows == nil)
    }

    @Test func rateFieldWritesArePositionalAndTyped() throws {
        var entry = ModelPrice()
        PanelLogic.applyRate(&entry, field: "input", value: 3.5)
        PanelLogic.applyRate(&entry, field: "output_peak", value: 7)
        PanelLogic.applyRate(&entry, field: "bogus", value: 99)
        #expect(entry.input == 3.5)
        #expect(entry.outputPeak == 7)
        #expect(entry.output == 0)
    }

    @Test func priceMapKeyMatchesExistingKeyIgnoringCase() {
        let prices = ["GLM-4.6@cc": ModelPrice(), "other": ModelPrice()]
        #expect(PanelLogic.priceMapKey(prices, model: "glm-4.6@cc") == "GLM-4.6@cc")
        #expect(PanelLogic.priceMapKey(prices, model: "brand-new") == "brand-new")
        #expect(PanelLogic.priceMapKey(prices, model: "OTHER") == "other")
    }

    @Test func rowUnionDedupesAndFlagsState() {
        let prices = [
            "glm-5.3@workbuddy": ModelPrice(input: 1.4, output: 4.4, cached: 0.26),
            "legacy-only": ModelPrice(input: 0, output: 0, cached: 0),
        ]
        let rows = PanelLogic.priceRows(prices: prices,
                                        recordModels: ["GLM-5.3@WorkBuddy", "kimi-k2@cc"])
        #expect(rows.count == 3)
        let glm = rows.first { $0.model == "GLM-5.3@WorkBuddy" }
        #expect(glm?.priced == true)
        #expect(glm?.inLog == true)
        #expect(glm?.peak == false)
        let legacy = rows.first { $0.model == "legacy-only" }
        #expect(legacy?.inLog == false)
        let kimi = rows.first { $0.model == "kimi-k2@cc" }
        #expect(kimi?.priced == false)
        #expect(kimi?.inLog == true)
    }

    @Test func rowsSortCaseInsensitiveLikeLocaleCompare() {
        let rows = PanelLogic.priceRows(prices: [:], recordModels: ["b", "A", "c10", "C9"])
        #expect(rows.map(\.model) == ["A", "b", "c10", "C9"])
    }

    @Test func uniqueByLowercasedDropsEmpties() {
        #expect(PanelLogic.uniqueByLowercased(["", "a", "A", "b", "a"]) == ["a", "b"])
    }

    @Test func rowModelsPreferAliasOverName() throws {
        func record(_ id: String, model: String, alias: String?) throws -> UsageRecord {
            let aliasPart = alias.map { ",\"alias\":\"\($0)\"" } ?? ""
            return try PanelJSON.decoder.decode(UsageRecord.self, from: Data(
                """
                {"id":"\(id)","timestamp":"2026-10-01T00:00:00Z","account":"a","model":"\(model)","status":200\(aliasPart)}
                """.utf8))
        }
        var entry = ProviderEntry(name: "cc")
        entry.models = [ProviderModelDef(name: "glm-4.6"), ProviderModelDef(name: "x", alias: "kept@cc")]
        let models = PanelLogic.priceRowModels(
            records: [try record("r1", model: "raw-model", alias: nil),
                      try record("r2", model: "raw-model", alias: "Pretty@cc"),
                      try record("r3", model: "blank-alias", alias: "")],
            providers: [entry])
        #expect(models == ["raw-model", "Pretty@cc", "blank-alias", "glm-4.6", "kept@cc"])
    }

    @Test func peakWindowRoundTripEncodesSnakeCase() throws {
        let decoded = try price(#"{"input":1,"output":2,"cached":0.5,"input_peak":3,"peak_windows":[[1,4],[6,10]]}"#)
        let encoded = String(decoding: try PanelJSON.encoder.encode(decoded), as: UTF8.self)
        #expect(encoded.contains("\"peak_windows\":[[1,4],[6,10]]"))
        #expect(encoded.contains("\"input_peak\":3"))

        var cleared = decoded
        cleared.inputPeak = nil
        cleared.peakWindows = nil
        let bare = String(decoding: try PanelJSON.encoder.encode(cleared), as: UTF8.self)
        #expect(!bare.contains("input_peak"))
        #expect(!bare.contains("peak_windows"))
        #expect(bare.contains("\"input\":1"))
    }
}
