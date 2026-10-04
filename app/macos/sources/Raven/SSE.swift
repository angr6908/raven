import Foundation

@MainActor
final class UsageStream {
    private(set) var isLive = false
    private(set) var droppedRecords = 0
    var onRecord: ((UsageRecord) -> Void)?
    var onSnapshot: (() -> Void)?
    var onStatus: ((Bool) -> Void)?

    private var task: Task<Void, Never>?
    private var generation = 0

    func resetDrops() {
        droppedRecords = 0
    }

    func start() {
        stop()
        generation += 1
        let myGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.generation == myGeneration {
                let connected = await self.runOnce()
                guard !Task.isCancelled, self.generation == myGeneration else { return }
                self.markOffline()
                try? await Task.sleep(for: .seconds(connected ? 1 : 3))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        markOffline(silent: true)
    }

    private func runOnce() async -> Bool {
        var pendingEvent = "message"
        guard let url = URL(string: LocalProxy.baseURL + "/api/usage/stream") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        await CoreProcess.shared.waitUntilReady()
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            markOnline()
            for try await line in bytes.lines {
                if Task.isCancelled { return true }
                pendingEvent = handle(line: line, pendingEvent: pendingEvent)
            }
            return true
        } catch {
            return false
        }
    }

    func handle(line raw: String, pendingEvent: String) -> String {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty { return pendingEvent }
        if line.hasPrefix(":") { return pendingEvent }
        if line.hasPrefix("event:") {
            let name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if name == "ready" {
                onSnapshot?()
            }
            return name
        }
        guard line.hasPrefix("data:") else { return pendingEvent }
        guard pendingEvent == "record" else { return pendingEvent }
        var payload = String(line.dropFirst(5))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        guard !payload.isEmpty else { return pendingEvent }
        do {
            let record = try PanelJSON.decoder.decode(UsageRecord.self, from: Data(payload.utf8))
            onRecord?(record)
        } catch {
            droppedRecords += 1
        }
        return pendingEvent
    }

    private func markOnline() {
        guard !isLive else { return }
        isLive = true
        onStatus?(true)
    }

    private func markOffline(silent: Bool = false) {
        guard isLive else { return }
        isLive = false
        if !silent { onStatus?(false) }
    }
}
