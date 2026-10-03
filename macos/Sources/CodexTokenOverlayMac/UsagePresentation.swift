import Foundation
import CodexTokenCore

struct UsageNumbers {
    let input: Int64?
    let cached: Int64?
    let output: Int64?
    let reasoning: Int64?
    let cacheCreation: Int64?
    let total: Int64?
    let cost: Double?

    init(input: Int64?, cached: Int64?, output: Int64?, reasoning: Int64?,
         cacheCreation: Int64? = nil, total: Int64? = nil, cost: Double? = nil) {
        self.input = input
        self.cached = cached
        self.output = output
        self.reasoning = reasoning
        self.cacheCreation = cacheCreation
        self.total = total
        self.cost = cost
    }

    init(day: CodexCostReport.Day?) {
        self.init(input: day?.inputTokens, cached: day?.cacheReadTokens, output: day?.outputTokens,
                  reasoning: day?.reasoningTokens, cacheCreation: day?.cacheCreationTokens,
                  total: day?.totalTokens, cost: day?.totalCost)
    }

    init(totals: CodexCostReport.Totals?) {
        self.init(input: totals?.inputTokens, cached: totals?.cacheReadTokens, output: totals?.outputTokens,
                  reasoning: totals?.reasoningTokens, cacheCreation: totals?.cacheCreationTokens,
                  total: totals?.totalTokens, cost: totals?.totalCost)
    }

    init(session: TokenSnapshot?, lastRequest: Bool) {
        self.init(input: lastRequest ? session?.lastInputTokens : session?.inputTokens,
                  cached: lastRequest ? session?.lastCachedInputTokens : session?.cachedInputTokens,
                  output: lastRequest ? session?.lastOutputTokens : session?.outputTokens,
                  reasoning: lastRequest ? session?.lastReasoningOutputTokens : session?.reasoningOutputTokens,
                  total: lastRequest ? session?.contextUsedTokens : session?.totalTokens)
    }

    var uncached: Int64? {
        guard let input, let cached, input >= 0, cached >= 0, cached <= input else { return nil }
        return input - cached
    }

    var cacheHitPercent: Double? {
        guard let input, input > 0, let cached, cached >= 0, cached <= input else { return nil }
        return Double(cached) / Double(input) * 100
    }

    var rows: [(String, String)] {
        [("Token 合计", UsageFormat.tokens(total)),
         ("输入（含缓存）", UsageFormat.tokens(input)),
         ("未缓存输入", UsageFormat.tokens(uncached)),
         ("缓存读取", UsageFormat.tokens(cached)),
         ("缓存命中率", UsageFormat.percent(cacheHitPercent)),
         ("缓存写入", UsageFormat.tokens(cacheCreation)),
         ("输出（含推理）", UsageFormat.tokens(output)),
         ("推理输出", UsageFormat.tokens(reasoning))]
    }
}

enum UsageFormat {
    static func tokens(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "未报告" }
        return value.formatted()
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "未报告" }
        return value.formatted(.number.precision(.fractionLength(0...2))) + "%"
    }

    static func money(_ value: Double?, currency: String = "USD") -> String {
        guard let value, value.isFinite, value >= 0 else { return "未报告" }
        return value.formatted(.currency(code: currency).precision(.fractionLength(2...4)))
    }

    static func date(_ value: String?) -> String {
        guard let value else { return "未报告" }
        guard let date = parsedDate(value) else { return value }
        return date.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
    }

    static func parsedDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        let basic = parser.date(from: value)
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return basic ?? parser.date(from: value)
    }

    static func menuReset(_ window: CodexQuotaReport.Window, now: Date = Date()) -> String {
        guard let date = parsedDate(window.resetsAt), let totalMinutes = Int(exactly: ceil(date.timeIntervalSince(now) / 60)) else {
            return window.resetDescription ?? "重置时间未报告"
        }
        if date.timeIntervalSince(now) < 1 { return "现在重置" }
        let days = totalMinutes / 1440
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 {
            if hours > 0 { return "\(days)天 \(hours)小时后重置" }
            if minutes > 0 { return "\(days)天 \(minutes)分钟后重置" }
            return "\(days)天后重置"
        }
        if hours > 0 {
            if minutes > 0 { return "\(hours)小时 \(minutes)分钟后重置" }
            return "\(hours)小时后重置"
        }
        return "\(max(1, totalMinutes))分钟后重置"
    }

    static func menuUpdated(_ value: String?, now: Date = Date()) -> String {
        guard let date = parsedDate(value), let seconds = Int(exactly: now.timeIntervalSince(date).rounded(.towardZero)) else { return "更新时间未报告" }
        if seconds > -60 && seconds < 60 { return "刚刚更新" }
        let relative = RelativeDateTimeFormatter()
        relative.locale = Locale(identifier: "zh_CN")
        relative.unitsStyle = .abbreviated
        return "更新于 " + relative.localizedString(for: date, relativeTo: now)
    }

    static func menuTokens(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "未报告" }
        let units: [(threshold: Int64, divisor: Double, suffix: String)] = [
            (999_500_000, 1_000_000_000, "B"), (999_500, 1_000_000, "M"), (1000, 1000, "K")]
        for unit in units where value >= unit.threshold {
            let scaled = Double(value) / unit.divisor
            var formatted = String(format: scaled >= 10 ? "%.0f" : "%.1f", scaled)
            if formatted.hasSuffix(".0") { formatted.removeLast(2) }
            return formatted + unit.suffix
        }
        return String(value)
    }

    static func menuPercent(_ value: Double) -> String {
        let clamped = min(100, max(0, value))
        return clamped > 0 && clamped < 1 ? "<1%" : String(format: "%.0f%%", clamped)
    }

    static func window(_ minutes: Int) -> String {
        if minutes > 0, minutes % 1440 == 0 { return "\(minutes / 1440) 天窗口" }
        if minutes > 0, minutes % 60 == 0 { return "\(minutes / 60) 小时窗口" }
        return "\(minutes) 分钟窗口"
    }
}
