import Foundation

nonisolated enum PanelError: LocalizedError {
    case notReachable
    case http(Int, String?)
    case api(code: String?, message: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notReachable: "Raven proxy is not running on 127.0.0.1:3458"
        case .http(let code, let message): message ?? "HTTP \(code)"
        case .api(_, let message): message
        case .decoding(let detail): "Unexpected response: \(detail)"
        }
    }

    var noticeText: String { errorDescription ?? "Something went wrong" }
}

private nonisolated struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        var message: String
        var code: String?
    }
    var error: Body
}

private nonisolated struct OkEnvelope: Decodable {
    var ok: Bool
    var error: String?
}

nonisolated struct PanelClient {
    static let shared = PanelClient()

    var baseURL: URL {
        let override = ProcessInfo.processInfo.environment["RAVEN_PANEL_URL"]
        return URL(string: override ?? LocalProxy.baseURL) ?? URL(string: LocalProxy.baseURL)!
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 20) async throws -> T {
        let data = try await send("GET", path: path, query: query, body: nil, timeout: timeout)
        return try decode(T.self, from: data, path: path)
    }

    func post<T: Decodable>(_ path: String, json: some Encodable) async throws -> T {
        let data = try await send("POST", path: path, query: [], body: try PanelJSON.encoder.encode(json), timeout: 20)
        return try decode(T.self, from: data, path: path)
    }

    func postVoid(_ path: String, json: some Encodable) async throws {
        _ = try await send("POST", path: path, query: [], body: try PanelJSON.encoder.encode(json), timeout: 20)
    }

    func putVoid(_ path: String, json: some Encodable) async throws {
        _ = try await send("PUT", path: path, query: [], body: try PanelJSON.encoder.encode(json), timeout: 20)
    }

    func delete(_ path: String, query: [URLQueryItem] = []) async throws {
        _ = try await send("DELETE", path: path, query: query, body: nil, timeout: 20)
    }

    private func send(_ method: String, path: String, query: [URLQueryItem], body: Data?, timeout: TimeInterval) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw PanelError.notReachable }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        await CoreProcess.shared.waitUntilReady()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PanelError.notReachable
        }
        guard let http = response as? HTTPURLResponse else { throw PanelError.notReachable }
        if !(200..<300).contains(http.statusCode) {
            if let envelope = try? PanelJSON.decoder.decode(ErrorEnvelope.self, from: data) {
                throw PanelError.api(code: envelope.error.code, message: envelope.error.message)
            }
            if let ok = try? PanelJSON.decoder.decode(OkEnvelope.self, from: data), ok.ok == false {
                throw PanelError.api(code: nil, message: ok.error ?? "HTTP \(http.statusCode)")
            }
            throw PanelError.http(http.statusCode, String(data: data, encoding: .utf8).flatMap {
                $0.isEmpty ? nil : String($0.prefix(200))
            })
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try PanelJSON.decoder.decode(type, from: data)
        } catch {
            throw PanelError.decoding("\(path): \(error)")
        }
    }
}
