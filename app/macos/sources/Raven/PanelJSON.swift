import Foundation

nonisolated enum PanelJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
}

nonisolated struct RFC3339Date: Decodable, Equatable {
    let date: Date?
    let raw: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        raw = try container.decode(String.self)
        date = RFC3339Date.parse(raw)
    }

    static func parse(_ string: String) -> Date? {
        cacheLock.lock()
        if let cached = cache[string] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let date = plainFormatter.date(from: string)
            ?? fractionalFormatter.date(from: string)
            ?? bareFormatter.date(from: string)

        cacheLock.lock()
        if cache.count < cacheLimit { cache[string] = date }
        cacheLock.unlock()
        return date
    }

    private static let cacheLock = NSLock()
    private static let cacheLimit = 200_000
    private nonisolated(unsafe) static var cache: [String: Date?] = [:]

    private nonisolated(unsafe) static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let bareFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter
    }()

    static func utcHour(_ string: String) -> Int? {
        guard let date = parse(string) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.component(.hour, from: date)
    }
}
