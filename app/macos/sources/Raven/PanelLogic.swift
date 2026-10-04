import Foundation

nonisolated enum PanelLogic {
    static let fallbackEffortLevels = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    static func aliasFor(modelName: String, providerName: String) -> String {
        "\(PanelAggregation.stripModelVendorAndProvider(modelName))@\(providerName)"
    }

    static func aliasOwner(_ entry: ProviderEntry) -> String {
        let name = entry.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty, entry.isManaged { return entry.kind ?? "" }
        return name
    }

    static func withAliases(_ entry: ProviderEntry) -> ProviderEntry {
        let owner = aliasOwner(entry)
        var updated = entry
        updated.models = entry.models.map { model in
            var model = model
            let name = model.name.trimmingCharacters(in: .whitespaces)
            model.alias = name.isEmpty || owner.isEmpty ? nil : aliasFor(modelName: model.name, providerName: owner)
            return model
        }
        return updated
    }

    static func withContext(_ model: ProviderModelDef, tokens: Int?) -> ProviderModelDef {
        var updated = model
        updated.maxContextLength = tokens
        return updated
    }

    static func withLevels(_ model: ProviderModelDef, next: [String]) -> ProviderModelDef {
        var updated = model
        var thinking = model.thinking ?? ThinkingShape()
        if next.isEmpty {
            if (thinking.min ?? 0) > 0 || (thinking.max ?? 0) > 0
                || thinking.zeroAllowed == true || thinking.dynamicAllowed == true {
                thinking.levels = nil
            } else {
                updated.thinking = nil
                return updated
            }
        } else {
            thinking.levels = next
        }
        updated.thinking = thinking
        return updated
    }

    typealias ProviderModelIndex = [String: [String]]

    static func buildProviderModelIndex(_ providers: [ProviderEntry]) -> ProviderModelIndex {
        var index: ProviderModelIndex = [:]
        for provider in providers {
            let name = provider.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            for model in provider.models {
                for key in [model.alias, model.name] {
                    guard let key else { continue }
                    let normalized = key.trimmingCharacters(in: .whitespaces).lowercased()
                    guard !normalized.isEmpty else { continue }
                    var names = index[normalized] ?? []
                    if !names.contains(name) { names.append(name) }
                    index[normalized] = names
                }
            }
        }
        return index
    }

    static func resolveModelDisplay(_ modelKey: String,
                                    _ index: ProviderModelIndex) -> (provider: String?, short: String) {
        let short = PanelAggregation.stripModelVendorAndProvider(modelKey)
        let names = index[modelKey.trimmingCharacters(in: .whitespaces).lowercased()]
        return (names?.count == 1 ? names?.first : nil, short)
    }

    static func blankProviderEntry(kind: String?, name: String = "") -> ProviderEntry {
        var entry = ProviderEntry(name: name)
        entry.disabled = false
        entry.kind = kind
        entry.baseUrl = ""
        entry.apiKeyEntries = []
        entry.models = []
        return entry
    }

    static func friendlyLookupError(_ message: String, what: String) -> String {
        if message.contains("HTTP 404") {
            return "Not found on models.dev — no \(what). Check the upstream model name."
        }
        return message.isEmpty ? "Failed to fetch \(what)" : message
    }

    static let defaultPeakWindows: [[Int]] = [[1, 4], [6, 10]]

    static func uniqueByLowercased(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in names where !name.isEmpty {
            let key = name.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                out.append(name)
            }
        }
        return out
    }

    static func priceMapKey(_ prices: [String: ModelPrice], model: String) -> String {
        let lower = model.lowercased()
        for key in prices.keys where key.lowercased() == lower {
            return key
        }
        return lower
    }

    static func preferredName(alias: String?, _ fallback: String) -> String {
        guard let alias, !alias.isEmpty else { return fallback }
        return alias
    }

    static func priceRowModels(records: [UsageRecord], providers: [ProviderEntry]) -> [String] {
        uniqueByLowercased(records.map { preferredName(alias: $0.alias, $0.model) }
            + providers.flatMap { $0.models.map { model in preferredName(alias: model.alias, model.name) } })
    }

    static func hasPeak(_ price: ModelPrice) -> Bool {
        (price.inputPeak ?? 0) > 0 || (price.outputPeak ?? 0) > 0
            || (price.cachedPeak ?? 0) > 0 || !(price.peakWindows ?? []).isEmpty
    }

    static func isPriced(_ price: ModelPrice) -> Bool {
        price.input > 0 || price.output > 0
    }

    static func priceRows(prices: [String: ModelPrice], recordModels: [String]) -> [PricingRowData] {
        let logSet = Set(recordModels.map { $0.lowercased() })
        let rows = uniqueByLowercased(recordModels + Array(prices.keys)).map { model in
            let price = prices[priceMapKey(prices, model: model)] ?? ModelPrice()
            return PricingRowData(model: model,
                                  price: price,
                                  peak: hasPeak(price),
                                  priced: isPriced(price),
                                  inLog: logSet.contains(model.lowercased()))
        }
        return rows.sorted { $0.model.localizedCompare($1.model) == .orderedAscending }
    }

    static func applyRate(_ price: inout ModelPrice, field: String, value: Double) {
        switch field {
        case "input": price.input = value
        case "output": price.output = value
        case "cached": price.cached = value
        case "input_peak": price.inputPeak = value
        case "output_peak": price.outputPeak = value
        case "cached_peak": price.cachedPeak = value
        default: break
        }
    }

    static func applyPeakToggle(_ price: inout ModelPrice, on: Bool) {
        guard on else {
            price.inputPeak = nil
            price.outputPeak = nil
            price.cachedPeak = nil
            price.peakWindows = nil
            return
        }
        if !((price.inputPeak ?? 0) > 0) { price.inputPeak = price.input * 2 }
        if !((price.outputPeak ?? 0) > 0) { price.outputPeak = price.output * 2 }
        if !((price.cachedPeak ?? 0) > 0) { price.cachedPeak = price.cached * 2 }
        if (price.peakWindows ?? []).isEmpty { price.peakWindows = defaultPeakWindows }
    }

    static func applyModelsDev(_ lookup: ModelsDevLookup, to price: inout ModelPrice) {
        if let input = lookup.input { price.input = input }
        if let output = lookup.output { price.output = output }
        if let cached = lookup.cacheRead { price.cached = cached }
        if let peakInput = lookup.peakInput { price.inputPeak = peakInput }
        if let peakOutput = lookup.peakOutput { price.outputPeak = peakOutput }
        if let peakCache = lookup.peakCacheRead { price.cachedPeak = peakCache }
        if lookup.peakInput != nil, (price.peakWindows ?? []).isEmpty {
            price.peakWindows = defaultPeakWindows
        }
    }
}
