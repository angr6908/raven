import Foundation
import Observation

@MainActor
@Observable
final class PricingStore {
    static let shared = PricingStore()

    private(set) var prices: [String: ModelPrice] = [:]
    private(set) var recordModels: [String] = []
    private(set) var loading = true
    private(set) var error: String?

    let saver = AutoSaveScheduler()
    private var loadTask: Task<Void, Never>?
    private var started = false
    private var dirty = false

    func start() {
        guard !started else { return }
        started = true
        load(quiet: false)
    }

    func refresh() {
        guard started else {
            start()
            return
        }
        load(quiet: true)
    }

    private func load(quiet: Bool) {
        if !quiet { loading = true }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let providersTask: [ProviderEntry] = (try? await PanelClient.shared.get("/api/providers")) ?? []
                let response: PricesResponse = try await PanelClient.shared.get("/api/prices")
                let providers = await providersTask
                guard !Task.isCancelled else { return }
                if !self.dirty { self.prices = response.prices }
                self.recordModels = PanelLogic.priceRowModels(
                    records: UsageStore.shared.records, providers: providers)
                self.error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? PanelError)?.noticeText ?? error.localizedDescription
            }
            self.loading = false
        }
    }

    func rows() -> [PricingRowData] {
        PanelLogic.priceRows(prices: prices, recordModels: recordModels)
    }

    func entry(for model: String) -> ModelPrice {
        prices[PanelLogic.priceMapKey(prices, model: model)] ?? ModelPrice()
    }

    func setRate(_ model: String, field: String, value: Double) {
        mutate(model) { price in
            PanelLogic.applyRate(&price, field: field, value: value)
        }
    }

    func togglePeak(_ model: String, on: Bool) {
        mutate(model) { price in
            PanelLogic.applyPeakToggle(&price, on: on)
        }
    }




    func setWindows(_ model: String, windows: [[Int]]) {
        mutate(model) { price in
            price.peakWindows = windows
        }
    }

    func removeModel(_ model: String) {
        let key = PanelLogic.priceMapKey(prices, model: model)
        var next = prices
        next.removeValue(forKey: key)
        prices = next
        scheduleSave()
    }

    func sweepDeletable(_ models: [String]) {
        let doomed = Set(models.map { PanelLogic.priceMapKey(prices, model: $0) })
        guard !doomed.isEmpty else { return }
        var next = prices
        for key in doomed {
            next.removeValue(forKey: key)
        }
        prices = next
        scheduleSave()
    }

    func applyLookup(_ model: String, _ lookup: ModelsDevLookup) {
        mutate(model) { price in
            PanelLogic.applyModelsDev(lookup, to: &price)
        }
    }

    func applyBatch(_ updates: [(String, ModelsDevLookup)]) {
        guard !updates.isEmpty else { return }
        let baseline = prices
        var merged: [String: ModelPrice] = [:]
        for (model, lookup) in updates {
            let key = PanelLogic.priceMapKey(baseline, model: model)
            var price = merged[key] ?? ModelPrice()
            PanelLogic.applyModelsDev(lookup, to: &price)
            merged[key] = price
        }
        var next = prices
        for (key, price) in merged {
            next[key] = price
        }
        dirty = true
        prices = next
        let snapshot = next
        saver.schedule { [weak self] in
            try await PanelClient.shared.postVoid("/api/prices", json: snapshot)
            self?.dirty = false
            UsageStore.shared.reprice()
        }
    }

    private func mutate(_ model: String, _ change: (inout ModelPrice) -> Void) {
        let key = PanelLogic.priceMapKey(prices, model: model)
        var price = prices[key] ?? ModelPrice()
        change(&price)
        var next = prices
        next[key] = price
        dirty = true
        prices = next
        scheduleSave()
    }

    private func scheduleSave() {
        dirty = true
        let snapshot = prices
        saver.schedule { [weak self] in
            try await PanelClient.shared.postVoid("/api/prices", json: snapshot)
            self?.dirty = false
            UsageStore.shared.reprice()
        }
    }

    nonisolated static func lookupModelsDev(_ model: String) async throws -> ModelsDevLookup {
        let name = PanelAggregation.stripModelVendorAndProvider(model)
        return try await PanelClient.shared.get("/api/models-dev",
                                                query: [URLQueryItem(name: "model", value: name)])
    }

    func fetchPrice(_ model: String) async -> PricingFetchOutcome {
        do {
            let lookup = try await Self.lookupModelsDev(model)
            if lookup.input == nil && lookup.output == nil && lookup.cacheRead == nil {
                return .empty
            }
            applyLookup(model, lookup)
            return .ok
        } catch {
            let message = (error as? PanelError)?.noticeText ?? error.localizedDescription
            return PanelLogic.friendlyLookupError(message, what: "pricing").hasPrefix("Not found") ? .empty : .error
        }
    }

    nonisolated static func lookupOutcome(_ model: String) async -> PriceLookupOutcome {
        let found = try? await lookupModelsDev(model)
        return PriceLookupOutcome(model: model, lookup: found)
    }

    func fetchAll(_ models: [String]) async -> PricingBatchOutcome {
        var updates: [(String, ModelsDevLookup)] = []
        var empty = 0
        var failed = 0
        let lookups = models.map { model in
            Task { await Self.lookupOutcome(model) }
        }
        for task in lookups {
            let outcome = await task.value
            guard let found = outcome.lookup else {
                failed += 1
                continue
            }
            if found.input == nil && found.output == nil && found.cacheRead == nil {
                empty += 1
            } else {
                updates.append((outcome.model, found))
            }
        }
        applyBatch(updates)
        return PricingBatchOutcome(priced: updates.count, empty: empty, failed: failed)
    }
}

nonisolated struct PriceLookupOutcome: Sendable {
    let model: String
    let lookup: ModelsDevLookup?
}

nonisolated enum PricingFetchOutcome {
    case ok, empty, error
}

nonisolated struct PricingBatchOutcome: Equatable {
    var priced: Int
    var empty: Int
    var failed: Int
}

nonisolated struct PricingRowData: Equatable, Sendable {
    var model: String
    var price: ModelPrice
    var peak: Bool
    var priced: Bool
    var inLog: Bool
}
