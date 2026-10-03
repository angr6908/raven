import Foundation

nonisolated enum UsagePeriod: String, CaseIterable {
    case fiveHour, weekly, monthly

    var header: String {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }
}

nonisolated enum QuotaCellContent: Equatable {
    case dash
    case badge(String, String?)
    case value(percent: String, reset: String?, title: String?, fraction: Double? = nil)
}

nonisolated struct QuotaColumn: Equatable {
    var key: String
    var group: String
    var window: String
    var header: String
}

nonisolated enum AccountQuota {
    static func quotaPercent(_ fraction: Double) -> String {
        let value = max(0, min(1, fraction)) * 100
        if value < 10 && value > 0 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }

    static func capFraction(used: Double?, cap: Double?) -> Double? {
        guard let used, let cap, cap > 0 else { return nil }
        return max(0, min(1, (cap - used) / cap))
    }

    static func quotaResetShort(fromEpochMs ms: Double?) -> String? {
        guard let ms, ms.isFinite else { return nil }
        let raw = (ms / 1000 - Date().timeIntervalSince1970) / 60
        let minutes = Int(raw.rounded())
        if minutes <= 0 { return "now" }
        let days = minutes / (60 * 24)
        let hours = (minutes % (60 * 24)) / 60
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutes % 60)m" }
        return "\(minutes)m"
    }

    static func quotaResetShort(iso: String?) -> String? {
        guard let iso, let date = PanelFormats.parseISO(iso) else { return nil }
        return quotaResetShort(fromEpochMs: date.timeIntervalSince1970 * 1000)
    }

    static func commandCodeCell(_ limits: LimitRow, period: UsagePeriod, first: Bool) -> QuotaCellContent {
        if limits.source == "reauth_required" {
            return first ? .badge("sign in again", nonEmpty(limits.error) ?? "Live quota data is unavailable") : .dash
        }
        if limits.source != "live" {
            return first ? .badge("unavailable", nonEmpty(limits.error) ?? "Live quota data is unavailable") : .dash
        }
        switch period {
        case .fiveHour:
            guard let fraction = capFraction(used: limits.fiveHourUsed, cap: positive(limits.fiveHourCap)) else { return .dash }
            return .value(percent: quotaPercent(fraction),
                          reset: quotaResetShort(fromEpochMs: positive(limits.fiveHourResetAt)),
                          title: "5-hour limit remaining",
                          fraction: fraction)
        case .weekly:
            guard let fraction = capFraction(used: limits.weeklyUsed, cap: positive(limits.weeklyCap)) else { return .dash }
            return .value(percent: quotaPercent(fraction),
                          reset: quotaResetShort(fromEpochMs: positive(limits.weeklyResetAt)),
                          title: "Weekly limit remaining",
                          fraction: fraction)
        case .monthly:
            let cap = limits.monthlyCap
            if cap <= 0 { return .dash }
            let remaining = min(limits.monthlyCredits, cap)
            var title = "\(numberText(remaining)) credits remaining of \(numberText(cap))"
            if limits.purchasedCredits > 0 {
                title += " · +\(numberText(limits.purchasedCredits)) purchased"
            }
            return .value(percent: quotaPercent(remaining / cap), reset: nil, title: title, fraction: remaining / cap)
        }
    }

    static let windowOrder = ["5h", "daily", "7d", "monthly"]
    static let groupOrder = ["Gemini", "Claude"]

    static func quotaWindow(_ label: String) -> String {
        if matches(label, "(?i)five[\\s-]?hour") { return "5h" }
        if matches(label, "(?i)weekly|week") { return "7d" }
        if matches(label, "(?i)daily|day") { return "daily" }
        if matches(label, "(?i)monthly|month") { return "monthly" }
        let stripped = replace(label, "(?i)\\s*limit\\s*remaining\\s*", "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? "limit" : stripped
    }

    static func quotaGroupName(_ label: String) -> String {
        let stripped = replace(label, "(?i)\\s*models?$", "")
            .trimmingCharacters(in: .whitespaces)
        if let range = stripped.range(of: "\\s+and\\s+", options: [.regularExpression, .caseInsensitive]) {
            let lead = String(stripped[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !lead.isEmpty { return lead }
        }
        if !stripped.isEmpty { return stripped }
        return label
    }

    static func windowRank(_ window: String) -> Int {
        windowOrder.firstIndex(of: window) ?? windowOrder.count
    }

    static func groupRank(_ label: String) -> Int {
        groupOrder.firstIndex(of: quotaGroupName(label)) ?? groupOrder.count
    }

    static func antigravityQuotaColumns(_ quotas: [QuotaAccount]) -> [QuotaColumn] {
        var order: [String] = []
        var seen: [String: QuotaColumn] = [:]
        for quota in quotas {
            for group in quota.groups ?? [] {
                let full = group.displayName ?? ""
                for bucket in group.buckets ?? [] {
                    let label = nonEmpty(bucket.displayName) ?? nonEmpty(bucket.bucketId) ?? "limit"
                    let window = quotaWindow(label)
                    let key = "\(full)::\(window)"
                    if seen[key] == nil {
                        seen[key] = QuotaColumn(key: key, group: full, window: window,
                                                header: "\(quotaGroupName(full)) \(window)")
                        order.append(key)
                    }
                }
            }
        }
        return order.compactMap { seen[$0] }.sorted { a, b in
            let rank = windowRank(a.window) - windowRank(b.window)
            if rank != 0 { return rank < 0 }
            let groupRankDiff = groupRank(a.group) - groupRank(b.group)
            if groupRankDiff != 0 { return groupRankDiff < 0 }
            return a.group < b.group
        }
    }

    static func antigravityCell(quota: QuotaAccount?, column: QuotaColumn, first: Bool) -> QuotaCellContent {
        guard let quota else { return .dash }
        if let error = nonEmpty(quota.error) {
            return first ? .badge("unavailable", error) : .dash
        }
        let group = (quota.groups ?? []).first { ($0.displayName ?? "") == column.group }
        let bucket = (group?.buckets ?? []).first {
            quotaWindow(nonEmpty($0.displayName) ?? nonEmpty($0.bucketId) ?? "limit") == column.window
        }
        guard let bucket else { return .dash }
        return .value(percent: quotaPercent(bucket.remainingFraction ?? 0),
                      reset: quotaResetShort(iso: nonEmpty(bucket.resetTime)),
                      title: column.header,
                      fraction: bucket.remainingFraction)
    }

    static func creditsText(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func numberText(_ value: Double) -> String {
        if value == value.rounded(), value.magnitude < 1e15 { return String(Int(value)) }
        return String(value)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func positive(_ value: Double) -> Double? {
        value > 0 ? value : nil
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression]) != nil
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: [.regularExpression])
    }
}
