import SwiftUI
import CodexTokenCore

enum CodexBarLayout {
    static let menuWidth: CGFloat = 310
    static let horizontalPadding: CGFloat = 20
    static let headerSpacing: CGFloat = 4
    static let sectionSpacing: CGFloat = 12
    static let progressHeight: CGFloat = 6
    static let codexColor = Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
}

struct CodexBarCardPresentation {
    struct Metric: Identifiable {
        let id: String
        let title: String
        let percent: Double?
        let reset: String
        let detail: String?
        let pace: Double?
        let paceOnTop: Bool
    }
    let account: String
    let plan: String
    let updated: String
    let metrics: [Metric]
    let credits: String?
    let today: String
    let period: String
    let cache: String
    let error: String?
    let coverage: String?

    @MainActor
    init(_ model: UsageModel) {
        let quota = model.quota
        let usage = quota?.usage
        account = usage?.redactedAccount ?? ""
        plan = usage?.identity?.loginMethod ?? usage?.loginMethod ?? ""
        updated = model.quotaBusy ? "正在刷新…" : UsageFormat.menuUpdated(usage?.updatedAt ?? model.cost?.updatedAt)
        var rows: [Metric] = []
        func append(_ window: CodexQuotaReport.Window?, id: String, title: String, pace: CodexQuotaReport.PaceWindow?) {
            guard let window else { return }
            let percent = window.remainingPercent == nil ? nil : window.usedPercent
            let detail = pace?.willLastToReset.map { $0 ? "按当前节奏可持续到重置" : "按当前节奏可能提前用尽" }
            rows.append(Metric(id: id, title: title, percent: percent,
                reset: UsageFormat.menuReset(window),
                detail: detail, pace: pace?.expectedUsedPercent, paceOnTop: (pace?.deltaPercent ?? 0) <= 0))
        }
        append(usage?.primary, id: "primary", title: "会话", pace: quota?.pace?.primary)
        append(usage?.secondary, id: "secondary", title: "每周", pace: quota?.pace?.secondary)
        append(usage?.tertiary, id: "tertiary", title: quota?.rateWindowLabels?.tertiary ?? "其他额度", pace: quota?.pace?.tertiary)
        for entry in usage?.extraRateWindows ?? [] {
            if entry.usageKnown != false { append(entry.window, id: entry.id, title: entry.title, pace: nil) }
        }
        metrics = rows
        if let snapshot = quota?.credits {
            let remaining = snapshot.balanceIsWorkspace == true && snapshot.balanceReadSucceeded == true
                ? snapshot.remaining : (snapshot.codexCreditLimit?.remaining ?? (snapshot.balanceReadSucceeded == true ? snapshot.remaining : nil))
            credits = remaining.flatMap { $0.isFinite && $0 >= 0 ? $0.formatted(.number.precision(.fractionLength(0...3))) : nil }
        } else { credits = nil }
        let todayNumbers = UsageNumbers(day: model.today)
        let currency = model.cost?.currencyCode ?? "USD"
        today = "今日：\(UsageFormat.money(todayNumbers.cost, currency: currency)) · \(UsageFormat.menuTokens(todayNumbers.total)) tokens"
        period = "\(model.costPeriod?.rawValue ?? model.period.rawValue)：\(UsageFormat.money(model.cost?.totals?.totalCost, currency: currency)) · \(UsageFormat.menuTokens(model.cost?.totals?.totalTokens)) tokens"
        cache = "缓存命中 \(UsageFormat.percent(todayNumbers.cacheHitPercent)) · 读取 \(UsageFormat.menuTokens(todayNumbers.cached))"
        error = model.quotaError ?? model.costError
        coverage = model.cost != nil && model.cost?.historyCoverageIsEstablished != true ? "历史尚未扫描完整，显示已读记录" : nil
    }
}

struct CodexBarUsageCard: View {
    let presentation: CodexBarCardPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: CodexBarLayout.headerSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Codex").font(.headline).fontWeight(.semibold)
                    Spacer()
                    Text(presentation.account).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(presentation.error ?? presentation.updated).font(.footnote)
                        .foregroundStyle(presentation.error == nil ? Color.secondary : .red).lineLimit(2)
                    Spacer()
                    Text(presentation.plan).font(.footnote).foregroundStyle(.secondary)
                }
                Divider().padding(.top, 2)
            }.padding(.top, 6).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: CodexBarLayout.sectionSpacing) {
                ForEach(presentation.metrics) { metric in
                    VStack(alignment: .leading, spacing: 6) {
                        CodexBarMetricHeader(title: metric.percent.map { "\(metric.title) \(UsageFormat.menuPercent($0)) 已用" } ?? metric.title, reset: metric.reset)
                        if let percent = metric.percent {
                            CodexBarProgressView(percent: percent, tint: CodexBarLayout.codexColor,
                                accessibilityLabel: "\(metric.title) 已用", pacePercent: metric.pace, paceOnTop: metric.paceOnTop)
                        } else { Text("用量未报告").font(.footnote).foregroundStyle(.secondary) }
                        if let detail = metric.detail { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                if presentation.metrics.isEmpty { Text("官方额度尚未读取").font(.subheadline).foregroundStyle(.secondary) }
                if let credits = presentation.credits {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Credits").font(.body).fontWeight(.medium)
                        Text("余额：\(credits)").font(.footnote).monospacedDigit()
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("费用").font(.body).fontWeight(.medium)
                    Text(presentation.today).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    Text(presentation.period).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    Text(presentation.cache).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("API 标价参考，不是订阅账单").font(.footnote).foregroundStyle(.secondary)
                    if let coverage = presentation.coverage { Text(coverage).font(.footnote).foregroundStyle(.secondary) }
                }
            }.padding(.top, 10).padding(.bottom, 6)
        }.padding(.horizontal, CodexBarLayout.horizontalPadding)
            .frame(width: CodexBarLayout.menuWidth, alignment: .leading)
            .foregroundStyle(Color(nsColor: .controlTextColor))
    }
}

struct CodexBarMetricHeader: View {
    let title: String
    let reset: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleLabel.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                resetLabel.fixedSize(horizontal: true, vertical: false)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                titleLabel.frame(maxWidth: .infinity, alignment: .leading)
                resetLabel.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
    private var titleLabel: some View { Text(title).font(.body).fontWeight(.medium).lineLimit(1) }
    private var resetLabel: some View { Text(reset).font(.footnote).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing) }
}
