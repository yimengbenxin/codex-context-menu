import SwiftUI
import Charts
import CodexTokenCore

struct UsageOverviewView: View {
    @ObservedObject var model: UsageModel
    @State private var tab = "概览"
    private let tabs = ["概览", "历史趋势", "项目明细"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("用量").font(.title2).fontWeight(.semibold)
                    Spacer()
                    if model.costBusy { ProgressView().controlSize(.small) }
                    Button("刷新", systemImage: "arrow.clockwise") { model.refreshCost(refresh: true) }.disabled(model.costBusy)
                        .controlSize(.small)
                }.padding(20)
                Picker("用量视图", selection: $tab) {
                    ForEach(tabs, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 16)
                Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                if tab == "概览" {
                    HStack {
                        Spacer(minLength: 0)
                        CodexBarUsageCard(presentation: CodexBarCardPresentation(model))
                            .padding(.vertical, 8)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        Spacer(minLength: 0)
                    }
                    GroupBox { liveUsage.padding(8) }
                    GroupBox {
                        DisclosureGroup("官方额度与账号明细") { quota.padding(.top, 10) }.padding(8)
                    }
                } else {
                    HStack {
                        Picker("统计范围", selection: $model.period) {
                            ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.menu)
                        Spacer()
                        if model.costBusy { ProgressView().controlSize(.small) }
                    }
                    if model.costPeriod != model.period, model.cost != nil {
                        InlineMessage(text: "正在读取\(model.period.rawValue)；目前仍显示\(model.costPeriod?.rawValue ?? "上次")快照。",
                                      symbol: "clock", color: .orange)
                    }
                    if tab == "历史趋势" { history } else { UsageProjectsView(report: model.cost) }
                }
                if let error = model.costError {
                    InlineMessage(text: "本地统计更新失败，旧快照可能已过时：\(error)", symbol: "exclamationmark.triangle", color: .red)
                }
                DisclosureGroup("数据来源、口径与隐私") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("复用 MIT 开源 CodexBar 0.70.0 原生统计与菜单绘制。不另外解析或重复计费。历史每分钟更新；监控对话跟随本地日志反馈更新，不能逐 Token 预知尚未报告的生成量。")
                        Text("输入已包含缓存读取；推理是输出的一部分。缓存命中率 = 缓存读取 / 输入，不把缓存或推理再加进总量。缺失字段显示未报告，不填成零。")
                        Text("API 标价参考费用不等于 ChatGPT 订阅扣费。官方账号额度可能包含其他设备；本机日志统计只覆盖当前设备。")
                        Text("本地历史统计禁止网络、限制项目文件访问。额度使用现有 Codex OAuth 访问官方接口，不读取浏览器 Cookie、不切换账号、不向社区作者上传聊天或凭据。")
                        Text("项目名称与路径来自日志元数据，不读取项目代码；日志缺失、归档或未完成扫描可能使统计不完整。")
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.onAppear { if model.cost == nil { model.refreshCost() } }
    }

    private var liveUsage: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("监控对话 · 最近一次模型请求", detail: "随日志更新")
            if let session = model.currentSession {
                HStack {
                    Text("对话 \(session.threadID.prefix(8))").textSelection(.enabled)
                    Spacer()
                    Text("日志快照 \(session.updatedAt.formatted(date: .omitted, time: .standard))")
                }.font(.caption).foregroundStyle(.secondary)
                UsageStatsGrid(numbers: UsageNumbers(session: session, lastRequest: true), showCost: false)
                Text("最近上下文报告 \(UsageFormat.tokens(session.contextUsedTokens)) / \(UsageFormat.tokens(session.contextWindowTokens)) Token；不同于累计消耗。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("此对话累计消耗") {
                    UsageStatsGrid(numbers: UsageNumbers(session: session, lastRequest: false), showCost: false).padding(.top, 8)
                }
            } else {
                Text("暂未取得监控对话的 Token 快照。Codex 报告用量后自动显示；不按账号额度反推 Token。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            heading("今日 · 本机已记录", detail: "历史每分钟更新")
            UsageStatsGrid(numbers: UsageNumbers(day: model.today), currency: model.cost?.currencyCode ?? "USD")
            if let date = model.cost?.updatedAt {
                Text("本地统计快照：\(UsageFormat.date(date))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("\(model.costPeriod?.rawValue ?? model.period.rawValue) · 本机记录", detail: "不是账号账单")
            UsageStatsGrid(numbers: UsageNumbers(totals: model.cost?.totals), currency: model.cost?.currencyCode ?? "USD")
            if let report = model.cost {
                if report.historyCoverageIsEstablished != true {
                    InlineMessage(text: "当前历史尚未扫描完整；先显示已读记录，后续自动补齐。", symbol: "info.circle", color: .orange)
                }
                if let count = report.incompleteRequestCount, count > 0 {
                    Text("包含 \(count) 条未完成请求；部分输出或费用尚未报告。").font(.caption).foregroundStyle(.orange)
                }
                if let coverage = report.coverage ?? report.totals?.coverage {
                    Text("计价覆盖：已计价 \(coverage.priced.map(String.init) ?? "未知") · 未定价 \(coverage.unpriced.map(String.init) ?? "未知") · 未计量 \(coverage.unmetered.map(String.init) ?? "未知") · 估算 \(coverage.estimated.map(String.init) ?? "未知")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let unpriced = coverage.unpriced, unpriced > 0 {
                        InlineMessage(text: "有 \(unpriced) 项未定价记录，费用仅覆盖可定价部分；不代表完整费用或订阅扣款。", symbol: "info.circle", color: .orange)
                    }
                }
                if let days = report.daily, !days.isEmpty {
                    heading("每日趋势", detail: days.count > 90 ? "图表展示最近 90 个记录日；明细保留全部" : "输入 / 输出分开显示")
                    Chart(Array(days.sorted { $0.date < $1.date }.suffix(90))) { day in
                        if let input = day.inputTokens { BarMark(x: .value("日期", day.date), y: .value("Token", input)).foregroundStyle(by: .value("类型", "输入")) }
                        if let output = day.outputTokens { BarMark(x: .value("日期", day.date), y: .value("Token", output)).foregroundStyle(by: .value("类型", "输出")) }
                    }.chartForegroundStyleScale(["输入": Color.accentColor, "输出": Color.orange])
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                        .chartYAxis {
                            AxisMarks { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let count = value.as(Double.self) { Text(count.formatted(.number.notation(.compactName).locale(Locale(identifier: "zh_CN")))) }
                                }
                            }
                        }.frame(height: 160)
                    UsageDailyDetailsView(days: days, currency: report.currencyCode ?? "USD")
                } else { Text("所选范围尚无已读取的本地记录。").foregroundStyle(.secondary) }
                DisclosureGroup("上游汇总与计费来源") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("今日上游汇总：\(UsageFormat.tokens(report.sessionTokens)) Token · \(UsageFormat.money(report.sessionCostUSD))")
                        Text("近 30 天上游汇总（仅在当前已读范围内）：\(UsageFormat.tokens(report.last30DaysTokens)) Token · \(UsageFormat.money(report.last30DaysCostUSD))")
                        Text("上游已计量费用：\(UsageFormat.money(report.meteredCostUSD))；未返回时不视作订阅扣费。")
                        Text("计费来源：\(report.provenance ?? report.totals?.provenance ?? "未报告") · 统计范围：\(report.reportingPeriod ?? "未报告")")
                        Text("数据源：\(report.source ?? "未报告") · \(UsageFormat.date(report.updatedAt))")
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
        }
    }

    private var quota: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("官方账号额度").font(.headline)
                Spacer()
                if model.quotaBusy { ProgressView().controlSize(.small) }
                Button(model.quota == nil ? "读取官方额度" : "刷新官方额度") { model.refreshQuota() }.disabled(model.quotaBusy)
            }
            if let report = model.quota, let usage = report.usage {
                HStack {
                    Text(usage.identity?.loginMethod ?? usage.loginMethod ?? "已登录账号")
                    Spacer()
                    if let account = usage.redactedAccount { Text(account).textSelection(.enabled) }
                }.font(.callout)
                if let organization = usage.identity?.accountOrganization ?? usage.accountOrganization {
                    Text("组织：\(organization)").font(.caption).foregroundStyle(.secondary)
                }
                if let window = usage.primary { UsageQuotaWindowView(window: window, title: report.rateWindowLabels?.primary ?? "主额度窗口", pace: report.pace?.primary) }
                if let window = usage.secondary { UsageQuotaWindowView(window: window, title: report.rateWindowLabels?.secondary ?? "第二额度窗口", pace: report.pace?.secondary) }
                if let window = usage.tertiary { UsageQuotaWindowView(window: window, title: report.rateWindowLabels?.tertiary ?? "其他额度窗口", pace: report.pace?.tertiary) }
                ForEach(usage.extraRateWindows ?? [], id: \.id) { entry in
                    if entry.usageKnown == false { Text("\(entry.title)：官方未报告用量").foregroundStyle(.secondary) }
                    else { UsageQuotaWindowView(window: entry.window, title: entry.title) }
                }
                UsageAccountDetailsView(report: report)
                Text("官方快照：\(UsageFormat.date(usage.updatedAt)) · 来源 \(report.source ?? "未报告")")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let report = model.quota {
                Text("官方本次未返回额度窗口；下方仅展示实际返回的账号数据。").foregroundStyle(.secondary)
                UsageAccountDetailsView(report: report)
            } else {
                Text("点击向官方查询额度、重置时间与可用余额；不运行模型、不消耗对话 Token。不会用本机 Token 猜官方剩余额度。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.quotaError {
                InlineMessage(text: "官方额度更新失败，旧快照可能已过时：\(error)", symbol: "exclamationmark.triangle", color: .red)
            }
            Toggle("自动刷新官方额度（每 5 分钟）", isOn: $model.automaticQuota)
                .onChange(of: model.automaticQuota) { _, enabled in if enabled { model.refreshQuota() } }
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        HStack { Text(title).font(.headline); Spacer(); Text(detail).font(.caption).foregroundStyle(.secondary) }
    }
}

struct UsageStatsGrid: View {
    let numbers: UsageNumbers
    var currency = "USD"
    var showCost = true
    var body: some View {
        let rows = numbers.rows + (showCost ? [("API 标价参考费用", UsageFormat.money(numbers.cost, currency: currency))] : [])
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.0) { title, value in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(value).monospacedDigit().textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
            }
        }.font(.subheadline)
    }
}
