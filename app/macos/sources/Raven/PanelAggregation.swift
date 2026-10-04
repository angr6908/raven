import Foundation

nonisolated struct UsageTotals {
    var input: Double = 0
    var output: Double = 0
    var cached: Double = 0
    var total: Double = 0
    var cost: Double = 0
    var requests: Int = 0
    var ttftSum: Double = 0
    var ttftCount: Int = 0
    var latSum: Double = 0
    var latCount: Int = 0
    var tpsSum: Double = 0
    var usedModels: Int = 0

    var avgTTFT: Double { ttftCount > 0 ? ttftSum / Double(ttftCount) : 0 }
    var avgLatency: Double { latCount > 0 ? latSum / Double(latCount) : 0 }
    var cacheRate: Double { input > 0 ? cached / input : 0 }
}

nonisolated struct UsageModelAgg {
    var model: String
    var requests: Int = 0
    var errors: Int = 0
    var input: Double = 0
    var output: Double = 0
    var cached: Double = 0
    var total: Double = 0
    var cost: Double = 0
    var latSum: Double = 0
    var ok: Int = 0
    var ttftSum: Double = 0
    var ttftOk: Int = 0
    var tpsSum: Double = 0
}

nonisolated struct UsagePoint {
    var timestamp: String
    var inputTokens: Double
    var outputTokens: Double
    var totalTokens: Double
    var cost: Double
    var requests: Int
}

nonisolated enum PanelAggregation {
    static func cacheRead(_ r: UsageRecord) -> Double {
        if let breakdown = r.tokenBreakdown { return Double(breakdown.input.cacheReadTokens) }
        return Double(r.cachedTokens)
    }

    static func inputTotal(_ r: UsageRecord) -> Double {
        if let breakdown = r.tokenBreakdown { return Double(breakdown.input.totalTokens) }
        return Double(r.inputTokens)
    }

    static func outputTotal(_ r: UsageRecord) -> Double {
        if let breakdown = r.tokenBreakdown { return Double(breakdown.output.totalTokens) }
        return Double(r.outputTokens)
    }

    static func recordEndTimeMs(_ r: UsageRecord) -> Double {
        guard let date = PanelFormats.parseISO(r.timestamp) else { return 0 }
        return date.timeIntervalSince1970 * 1000 + Double(r.latencyMs)
    }

    static func totals(_ records: [UsageRecord]) -> UsageTotals {
        var acc = UsageTotals()
        var models = Set<String>()
        for r in records {
            models.insert(r.displayKey)
            acc.input += inputTotal(r)
            acc.output += outputTotal(r)
            acc.cached += cacheRead(r)
            acc.total += Double(r.totalTokens)
            acc.cost += r.costUsd
            acc.requests += 1
            if r.status < 400 {
                if r.ttftMs > 0 && r.ttftMs <= r.latencyMs {
                    acc.ttftSum += Double(r.ttftMs)
                    acc.ttftCount += 1
                }
                acc.latSum += Double(r.latencyMs)
                acc.latCount += 1
                acc.tpsSum += PanelFormats.tps(outputTokens: r.outputTokens, latencyMs: r.latencyMs) ?? 0
            }
        }
        acc.usedModels = models.count
        return acc
    }

    static func byModel(_ records: [UsageRecord]) -> [UsageModelAgg] {
        var order: [String] = []
        var map: [String: UsageModelAgg] = [:]
        for r in records {
            let key = r.displayKey
            var m = map[key]
            if m == nil {
                m = UsageModelAgg(model: key)
                order.append(key)
            }
            guard var agg = m else { continue }
            agg.requests += 1
            if r.status >= 400 { agg.errors += 1 }
            agg.input += inputTotal(r)
            agg.output += outputTotal(r)
            agg.cached += cacheRead(r)
            agg.total += Double(r.totalTokens)
            agg.cost += r.costUsd
            if r.status < 400 {
                agg.ok += 1
                agg.latSum += Double(r.latencyMs)
                if r.ttftMs > 0 && r.ttftMs <= r.latencyMs {
                    agg.ttftSum += Double(r.ttftMs)
                    agg.ttftOk += 1
                }
                agg.tpsSum += PanelFormats.tps(outputTokens: r.outputTokens, latencyMs: r.latencyMs) ?? 0
            }
            map[key] = agg
        }
        return order.compactMap { map[$0] }.sorted { $0.total > $1.total }
    }

    static func hourly(_ records: [UsageRecord]) -> [UsagePoint] {
        var order: [String] = []
        var map: [String: UsagePoint] = [:]
        for r in records {
            let ts = PanelFormats.hourBucket(r.timestamp)
            var point = map[ts]
            if point == nil {
                point = UsagePoint(timestamp: ts, inputTokens: 0, outputTokens: 0, totalTokens: 0, cost: 0, requests: 0)
                order.append(ts)
            }
            guard var bucket = point else { continue }
            bucket.inputTokens += inputTotal(r)
            bucket.outputTokens += outputTotal(r)
            bucket.totalTokens += Double(r.totalTokens)
            bucket.cost += r.costUsd
            bucket.requests += 1
            map[ts] = bucket
        }
        return order.compactMap { map[$0] }.sorted { $0.timestamp < $1.timestamp }
    }

    static func stripModelVendorAndProvider(_ model: String) -> String {
        var name = model.trimmingCharacters(in: .whitespaces)
        if let at = name.lastIndex(of: "@"), at != name.startIndex {
            name = String(name[..<at])
        }
        if let slash = name.lastIndex(of: "/"), name.index(after: slash) != name.endIndex {
            name = String(name[name.index(after: slash)...])
        }
        return name
    }
}
