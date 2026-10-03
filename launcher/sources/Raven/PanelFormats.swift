import Foundation

nonisolated enum PanelFormats {
    static func formatTokens(_ n: Double) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", n / 1_000) }
        if n == n.rounded() { return String(Int(n)) }
        return String(format: "%.1f", n)
    }

    static func formatTokens(_ n: Int) -> String {
        formatTokens(Double(n))
    }

    static func formatPercent(_ ratio: Double) -> String {
        String(format: "%.0f%%", ratio * 100)
    }

    static func formatCost(_ usd: Double) -> String {
        if usd == 0 { return "$0.00" }
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        return String(format: "$%.2f", usd)
    }

    static func rate(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return trimmingZeros(String(format: "%.6f", value))
    }

    static func formatDuration(_ ms: Double) -> String {
        if ms <= 0 { return "—" }
        if ms < 1000 { return "\(max(1, Int(ms.rounded())))ms" }
        return String(format: "%.2fs", ms / 1000)
    }

    static func formatContextWindow(_ n: Int) -> String {
        if n <= 0 { return "" }
        if n % 1_000_000 == 0 { return "\(n / 1_000_000)M" }
        if n >= 1_000_000 {
            let text = String(format: "%.2f", Double(n) / 1_000_000)
            return trimmingZeros(text) + "M"
        }
        if n >= 1_000 { return "\(Int((Double(n) / 1_000).rounded()))K" }
        return String(n)
    }

    private static func trimmingZeros(_ text: String) -> String {
        var value = text
        if value.contains(".") {
            while value.hasSuffix("0") { value.removeLast() }
            if value.hasSuffix(".") { value.removeLast() }
        }
        return value
    }

    static func tps(outputTokens: Int, latencyMs: Int) -> Double? {
        guard latencyMs > 0 else { return nil }
        return Double(outputTokens) / (Double(latencyMs) / 1000)
    }

    static func formatDateTime(iso: String) -> String {
        guard let date = parseISO(iso) else { return "" }
        return shortFormatter.string(from: date)
    }

    static func formatDateTime(_ date: Date) -> String {
        shortFormatter.string(from: date)
    }

    static func hourBucket(_ iso: String) -> String {
        guard let date = parseISO(iso) else {
            return iso.count >= 13 ? String(iso.prefix(13)) : iso
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return String(format: "%04d-%02d-%02dT%02d:00:00Z",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0, components.hour ?? 0)
    }

    static func hourLabel(_ iso: String) -> String {
        guard let date = parseISO(iso) else { return "" }
        return hourFormatter.string(from: date)
    }

    static func parseISO(_ iso: String) -> Date? {
        RFC3339Date.parse(iso)
    }

    static func parseTokenCount(_ text: String) -> Int? {
        var cleaned = text.trimmingCharacters(in: .whitespaces).lowercased()
        for separator in [",", "_", " "] {
            cleaned = cleaned.replacingOccurrences(of: separator, with: "")
        }
        guard !cleaned.isEmpty else { return nil }
        let scale: Double
        let number: Substring
        if cleaned.hasSuffix("m") {
            scale = 1_000_000
            number = cleaned.dropLast()
        } else if cleaned.hasSuffix("k") {
            scale = 1_000
            number = cleaned.dropLast()
        } else {
            scale = 1
            number = Substring(cleaned)
        }
        guard let value = Double(number), value.isFinite else { return nil }
        let tokens = Int((value * scale).rounded())
        return tokens > 0 ? tokens : nil
    }

    static func countdown(fromEpochMs ms: Double) -> String {
        let seconds = max(0, ms / 1000 - Date().timeIntervalSince1970)
        let days = Int(seconds / 86_400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400)) / 3_600
        if days > 0 { return "\(days)d \(hours)h" }
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3_600)) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private static let shortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d HH:mm")
        return formatter
    }()

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d HH")
        return formatter
    }()
}
