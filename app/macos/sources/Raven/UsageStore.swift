import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    static var cacheDirectoryOverride: URL?

    private(set) var records: [UsageRecord] = []
    private(set) var error: String?
    private(set) var isLive = false
    private(set) var isProxyUp = true
    private(set) var revision = 0
    private(set) var cacheWasStale = false

    var droppedRecords: Int { stream.droppedRecords }

    private let stream = UsageStream()
    private var started = false
    private var snapshotPending = false
    private var repriceQueued = false
    private var healthTask: Task<Void, Never>?

    static let maxRecords = 2000

    private init() {
        if let loaded = PanelCache.loadUsage(Self.cacheURL) {
            records = loaded
        } else {
            cacheWasStale = true
            PanelCache.quarantine(Self.cacheURL)
        }
    }

    private static var cacheURL: URL {
        (cacheDirectoryOverride ?? ProviderStore.configDirectory)
            .appending(path: "panel-usage-cache.json")
    }

    func start() {
        guard !started else { return }
        started = true
        stream.onRecord = { [weak self] record in
            self?.ingest(record)
        }
        stream.onSnapshot = { [weak self] in
            self?.fetchSnapshot()
        }
        stream.onStatus = { [weak self] live in
            guard let self else { return }
            self.isLive = live
            if live { self.fetchSnapshot() }
        }
        Task { await self.checkHealth() }
        stream.start()
        startHealthPoll()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.25))
            self?.fetchSnapshot()
        }
    }

    private func startHealthPoll() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self?.checkHealth()
            }
        }
    }

    func stop() {
        stream.stop()
        healthTask?.cancel()
        started = false
        isLive = false
    }

    func fetchSnapshot(reprice: Bool = false) {
        guard !snapshotPending else {
            if reprice { repriceQueued = true }
            return
        }
        snapshotPending = true
        Task { [weak self] in
            guard let self else { return }
            let repriced = reprice || self.repriceQueued
            self.repriceQueued = false
            do {
                let response: UsageListResponse = try await PanelClient.shared.get("/api/usage")
                self.apply(response.data, reprice: repriced)
                self.error = nil
                self.stream.resetDrops()
            } catch {
                self.error = (error as? PanelError)?.noticeText ?? error.localizedDescription
            }
            self.snapshotPending = false
            if self.repriceQueued {
                self.repriceQueued = false
                self.fetchSnapshot(reprice: true)
            }
        }
    }

    func reprice() {
        fetchSnapshot(reprice: true)
    }


    func clear() async -> String? {
        do {
            try await PanelClient.shared.delete("/api/usage")
            records = []
            PanelCache.saveUsage(records, to: Self.cacheURL)
            bumpRevision()
            return nil
        } catch {
            return (error as? PanelError)?.noticeText ?? error.localizedDescription
        }
    }

    func checkHealth() async {
        do {
            let health: HealthResponse = try await PanelClient.shared.get("/api/health")
            isProxyUp = health.status == "ok"
            error = nil
        } catch {
            isProxyUp = false
        }
    }

    func bumpRevision() {
        revision += 1
    }

    private func ingest(_ record: UsageRecord) {
        let key = record.requestId ?? record.timestamp
        guard !records.contains(where: { ($0.requestId ?? $0.timestamp) == key }) else { return }
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records.removeLast(records.count - Self.maxRecords)
        }
        PanelCache.saveUsage(records, to: Self.cacheURL)
        bumpRevision()
    }

    private func apply(_ fresh: [UsageRecord], reprice: Bool) {
        guard !records.isEmpty else {
            records = Array(fresh.prefix(Self.maxRecords))
            PanelCache.saveUsage(records, to: Self.cacheURL)
            bumpRevision()
            return
        }
        var freshByKey: [String: UsageRecord] = [:]
        freshByKey.reserveCapacity(fresh.count)
        for record in fresh {
            freshByKey[record.requestId ?? record.timestamp] = record
        }
        var changed = false
        var merged = records
        for index in merged.indices {
            let key = merged[index].requestId ?? merged[index].timestamp
            if reprice, let server = freshByKey[key], server != merged[index] {
                merged[index] = server
                changed = true
            }
        }
        let seen = Set(merged.map { $0.requestId ?? $0.timestamp })
        for record in fresh where !seen.contains(record.requestId ?? record.timestamp) {
            merged.append(record)
            changed = true
        }
        guard changed else { return }
        merged.sort { PanelAggregation.recordEndTimeMs($0) > PanelAggregation.recordEndTimeMs($1) }
        records = Array(merged.prefix(Self.maxRecords))
        PanelCache.saveUsage(records, to: Self.cacheURL)
        bumpRevision()
    }
}

nonisolated enum PanelCache {
    static func loadUsage(_ url: URL) -> [UsageRecord]? {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return try? PanelJSON.decoder.decode([UsageRecord].self, from: data)
    }

    static func saveUsage(_ records: [UsageRecord], to url: URL) {
        guard let data = try? PanelJSON.encoder.encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func loadQuota(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    static func saveQuota(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
    }

    static func quarantine(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = url.deletingLastPathComponent()
            .appending(path: "\(url.deletingPathExtension().lastPathComponent).corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: target)
    }
}
