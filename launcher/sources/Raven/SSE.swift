import Foundation

nonisolated struct SSEFrame: Equatable {
    var event: String
    var data: String
}

nonisolated enum SSEParser {
    static func frames(from lines: some Sequence<String>) -> [SSEFrame] {
        var result: [SSEFrame] = []
        var event = ""
        var data: [String] = []

        for raw in lines {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty {
                if !data.isEmpty {
                    result.append(SSEFrame(event: event.isEmpty ? "message" : event,
                                           data: data.joined(separator: "\n")))
                }
                event = ""
                data = []
                continue
            }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
                event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                data.append(value)
            } else if line.hasPrefix("id:") {
                continue
            } else if line.hasPrefix("retry:") {
                continue
            }
        }
        return result
    }

    static func recordLine(from frame: SSEFrame) -> String? {
        if frame.event == "record" { return frame.data }
        if frame.event == "message" {
            if let json = try? PanelJSON.decoder.decode(EnvelopeLine.self, from: Data(frame.data.utf8)),
               json.type == "record", let payload = json.raw {
                return payload
            }
        }
        return nil
    }

    private nonisolated struct EnvelopeLine: Decodable {
        var type: String?
        var data: JSONValue?

        enum CodingKeys: String, CodingKey {
            case type
            case data
        }

        var raw: String? {
            guard let data else { return nil }
            if case .string(let text) = data { return text }
            guard let encoded = try? PanelJSON.encoder.encode(data) else { return nil }
            return String(decoding: encoded, as: UTF8.self)
        }
    }
}

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
