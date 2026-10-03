import SwiftUI
import CodexTokenCore

struct UsageDailyDetailsView: View {
    let days: [CodexCostReport.Day]
    var currency = "USD"
    var body: some View {
        DisclosureGroup("每日完整明细（\(days.count) 天）") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(days.sorted { $0.date > $1.date }) { day in
                    DisclosureGroup(day.date) {
                        VStack(alignment: .leading, spacing: 12) {
                            UsageStatsGrid(numbers: UsageNumbers(day: day), currency: currency)
                            if let models = day.modelsUsed { Text("使用模型：\(models.joined(separator: "、"))").font(.caption).foregroundStyle(.secondary) }
                            UsageModelRows(rows: day.modelBreakdowns ?? [], currency: currency)
                            if let count = day.incompleteRequestCount, count > 0 { Text("\(count) 条请求尚未完整计量").font(.caption).foregroundStyle(.orange) }
                        }.padding(.vertical, 8)
                    }
                }
            }.padding(.top, 10)
        }
    }
}

struct UsageModelRows: View {
    let rows: [CodexCostReport.ModelBreakdown]
    var currency = "USD"
    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("模型明细").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.modelName).textSelection(.enabled)
                        Spacer()
                        Text("\(UsageFormat.tokens(row.totalTokens)) Token").monospacedDigit()
                        Text(UsageFormat.money(row.cost, currency: currency)).monospacedDigit()
                    }.font(.caption)
                }
            }
        }
    }
}

struct UsageProjectsView: View {
    let report: CodexCostReport?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("项目与会话来源").font(.headline)
            Text("按日志中的项目元数据归组；不扫描项目代码或 Git 工作区。只覆盖所选历史范围。").font(.caption).foregroundStyle(.secondary)
            if let projects = report?.projects, !projects.isEmpty {
                ForEach(Array(projects.enumerated()), id: \.offset) { _, project in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            if let path = project.path { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            UsageModelRows(rows: project.modelBreakdowns ?? [], currency: report?.currencyCode ?? "USD")
                            UsageDailyDetailsView(days: project.daily ?? [], currency: report?.currencyCode ?? "USD")
                            ForEach(Array((project.sources ?? []).enumerated()), id: \.offset) { _, source in
                                DisclosureGroup("来源 · \(source.name)") {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("\(UsageFormat.tokens(source.totalTokens)) Token · \(UsageFormat.money(source.totalCost, currency: report?.currencyCode ?? "USD")) API 标价参考")
                                        if let path = source.path { Text(path).textSelection(.enabled).foregroundStyle(.secondary) }
                                        UsageModelRows(rows: source.modelBreakdowns ?? [], currency: report?.currencyCode ?? "USD")
                                        UsageDailyDetailsView(days: source.daily ?? [], currency: report?.currencyCode ?? "USD")
                                    }.font(.caption).padding(.vertical, 8)
                                }
                            }
                        }.padding(.vertical, 8)
                    } label: {
                        HStack {
                            Text(project.name).fontWeight(.medium)
                            Spacer()
                            Text("\(UsageFormat.tokens(project.totalTokens)) Token").monospacedDigit()
                            Text(UsageFormat.money(project.totalCost, currency: report?.currencyCode ?? "USD")).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
            } else { Text("当前范围尚无项目记录。等待扫描完成，或更改统计范围。").foregroundStyle(.secondary) }
        }
    }
}

struct UsageQuotaWindowView: View {
    let window: CodexQuotaReport.Window
    let title: String
    var pace: CodexQuotaReport.PaceWindow?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Text("已用 \(UsageFormat.percent(window.isSyntheticPlaceholder == true ? nil : window.usedPercent)) · 剩余 \(UsageFormat.percent(remaining))").monospacedDigit()
            }.font(.callout)
            if remaining != nil, let used = window.usedPercent {
                CodexBarProgressView(percent: used, tint: CodexBarLayout.codexColor, accessibilityLabel: "\(title) 已用",
                    pacePercent: pace?.expectedUsedPercent, paceOnTop: (pace?.deltaPercent ?? 0) <= 0)
            }
            HStack {
                if let minutes = window.windowMinutes { Text(UsageFormat.window(minutes)) }
                Text("重置：\(window.resetsAt == nil ? (window.resetDescription ?? "未报告") : UsageFormat.date(window.resetsAt))")
            }.font(.caption).foregroundStyle(.secondary)
            if let pace {
                DisclosureGroup("额度使用节奏（上游预测）") {
                    VStack(alignment: .leading, spacing: 5) {
                        if let enough = pace.willLastToReset { Text(enough ? "按当前快照，预计可持续到重置" : "按当前快照，预计可能提前用尽") }
                        if let expected = pace.expectedUsedPercent { Text("当前时点预期已用：\(UsageFormat.percent(expected))") }
                        if let delta = pace.deltaPercent, delta.isFinite { Text("与预期差值：\(delta.formatted(.number.precision(.fractionLength(0...2)))) 个百分点（正值表示超出预期）") }
                        if let seconds = pace.etaSeconds, seconds.isFinite, seconds >= 0 { Text("快照预计还能持续：\((seconds / 3600).formatted(.number.precision(.fractionLength(0...1)))) 小时") }
                        if let summary = pace.summary { Text(summary) }
                        Text("预测不保证未来额度；不使用未报告的概率。").foregroundStyle(.secondary)
                    }.font(.caption).padding(.top, 6)
                }.font(.caption)
            }
        }
    }

    private var remaining: Double? {
        return window.remainingPercent
    }
}

struct UsageAccountDetailsView: View {
    let report: CodexQuotaReport
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let credits = report.credits {
                DisclosureGroup("官方余额与 Credits") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("余额：\(quantity(balance(credits))) · \(UsageFormat.date(credits.updatedAt))")
                        if credits.creditsAvailable == false { Text("官方报告当前没有可用 Credits").foregroundStyle(.secondary) }
                        if let limit = credits.codexCreditLimit {
                            Text(limit.title ?? "额度限制").fontWeight(.medium)
                            Text("已用 \(quantity(limit.used)) / 上限 \(quantity(limit.limit)) · 剩余 \(quantity(limit.remaining))（\(UsageFormat.percent(limit.remainingPercent))）")
                            Text("重置：\(UsageFormat.date(limit.resetsAt))")
                        }
                        ForEach(Array((credits.events ?? []).enumerated()), id: \.offset) { _, event in
                            Text("\(UsageFormat.date(event.date)) · \(event.service ?? "未报告服务") · 使用 \(quantity(event.creditsUsed))")
                        }
                        Text("余额与订阅额度、API 标价参考费用分开计算，不互相换算。").foregroundStyle(.secondary)
                    }.font(.caption).padding(.top, 8)
                }
            } else { Text("官方没有返回 Credits 余额；不把未知余额显示成零。").font(.caption).foregroundStyle(.secondary) }
            if let cost = report.usage?.providerCost {
                DisclosureGroup("官方费用快照") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已用 \(UsageFormat.money(cost.used, currency: cost.currencyCode ?? "USD")) / 上限 \(UsageFormat.money(cost.limit, currency: cost.currencyCode ?? "USD"))")
                        Text("个人用量：\(UsageFormat.money(cost.personalUsed, currency: cost.currencyCode ?? "USD"))")
                        Text("余额：\(UsageFormat.money(cost.balanceIsUnavailable == true ? nil : cost.balance, currency: cost.currencyCode ?? "USD"))")
                        Text("周期：\(cost.period ?? "未报告") · 重置 \(UsageFormat.date(cost.resetsAt))")
                        Text("快照：\(UsageFormat.date(cost.updatedAt)) · 余额快照 \(UsageFormat.date(cost.balanceUpdatedAt))")
                    }.font(.caption).padding(.top, 8)
                }
            }
            if let status = report.status {
                Text("官方服务状态：\(status.description ?? status.indicator ?? "未报告") · \(UsageFormat.date(status.updatedAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let diagnostic = report.diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }

    private func balance(_ credits: CodexQuotaReport.Credits) -> Double? {
        if credits.balanceIsWorkspace == true, credits.balanceReadSucceeded == true { return credits.remaining }
        if let value = credits.codexCreditLimit?.remaining { return value }
        return credits.balanceReadSucceeded == true ? credits.remaining : nil
    }

    private func quantity(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "未报告" }
        return value.formatted(.number.precision(.fractionLength(0...3)))
    }
}
