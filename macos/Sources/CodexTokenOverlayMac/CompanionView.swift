import AppKit
import SwiftUI
import Charts
import CodexTokenCore

struct CompanionView: View {
    @ObservedObject var model: ContextSettingsModel
    @ObservedObject var usage: UsageModel
    let chooseProject: () -> Void
    let identify: () -> Void
    let locateLink: () -> Void
    let close: () -> Void
    @AppStorage("contextUI.appearance") private var appearance = "system"

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: Binding<CompanionPage?>(get: { model.page }, set: { if let page = $0 { model.page = page } })) {
                    Section("Codex 上下文") {
                        ForEach(CompanionPage.allCases) { page in
                            Label(page.rawValue, systemImage: page.symbol).tag(page)
                        }
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 6) {
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }.pickerStyle(.menu).controlSize(.small)
                    Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版") · CodexBar 0.70.0")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }.frame(width: 260).background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            Group {
                if model.page == .context {
                    ContextSettingsView(model: model, chooseProject: chooseProject, identify: identify, locateLink: locateLink, close: close)
                } else {
                    UsageOverviewView(model: usage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disclosureGroupStyle(FullWidthDisclosureStyle())
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(appearance == "light" ? .light : (appearance == "dark" ? .dark : nil))
    }
}

struct ContextSettingsView: View {
    @ObservedObject var model: ContextSettingsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let chooseProject: () -> Void
    let identify: () -> Void
    let locateLink: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("上下文设置").font(.title2).fontWeight(.semibold)
                        Text("选择策略，让上下文跟上你的任务。").foregroundStyle(.secondary)
                    }
                    if let reason = model.runtimeReason {
                        VStack(alignment: .leading, spacing: 10) {
                            InlineMessage(text: reason, symbol: "gearshape", color: .orange)
                            Button(model.repairingRuntime ? "正在检查并接入…" : "完成组件接入 / 重新验证") { model.repairRuntime() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.repairingRuntime || model.saving || model.loading || model.identifying)
                            Text("只复制 .app 不等于已接入。这里会检查官方协议并安装本工具的运行组件，不改官方应用或聊天记录。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button(action: identify) { Label("识别当前对话", systemImage: "scope") }
                                .help("读取 Codex 当前或最近选中的窗口标题，精确匹配对话。需辅助功能权限；不读取聊天正文。")
                                .buttonStyle(.borderedProminent)
                            Button("手动选择项目…", action: chooseProject)
                            if model.identifying { ProgressView().controlSize(.small) }
                        }
                        HStack {
                            TextField("粘贴 codex://threads/… 深度链接", text: $model.targetLink)
                                .textFieldStyle(.roundedBorder).accessibilityLabel("目标对话深度链接")
                            Button("定位链接", action: locateLink).disabled(model.targetLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .disabled(model.loading || model.saving || model.identifying)
                    if model.project == nil {
                        ContentUnavailableView {
                            Label("先定位要修改的对话", systemImage: "bubble.left")
                        } description: {
                            Text("点击识别，或粘贴深度链接。无需向对话发送指令。")
                        } actions: {
                            Button("识别当前对话", action: identify).controlSize(.large)
                        }
                        .frame(minHeight: 250)
                    } else {
                        projectHeader
                        if model.loading {
                            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在读取项目设置…") }
                                .frame(maxWidth: .infinity, minHeight: 240)
                        } else if let status = model.status {
                            strategy(status)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("自动压缩线").font(.headline)
                                HStack {
                                    TextField("官方默认", text: $model.compactionInput)
                                        .textFieldStyle(.roundedBorder).frame(width: 120)
                                        .accessibilityLabel("自动压缩百分比").disabled(model.saving)
                                    Text("% · 上限99%，留空跟随官方").font(.caption).foregroundStyle(.secondary)
                                }
                                if model.compactionWarning {
                                    Text("超过90%可能在单轮对话中越过压缩线，请留意上下文余量。")
                                        .font(.caption).foregroundStyle(.red)
                                }
                                if let validation = model.compactionValidation {
                                    Text(validation).font(.caption).foregroundStyle(.red)
                                }
                                Text("压缩线不超过模型原始上限的90%；自适应升档后会重新限幅。自定义时，最近运行窗口会随触发线调整。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            activation(status)
                            DisclosureGroup("生效规则与范围") {
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(model.scope == .thread ? "仅影响锁定的对话 ID；同项目其他对话与新分支不变。" : "影响此项目下所有未设置个人覆盖的对话。")
                                    Text("不修改模型、压缩强度、全局配置或聊天记录。")
                                    Text("官方模型上限及保留比例仍然适用，输入值不等于最终可用窗口。")
                                    Text("其他客户端订阅或无法完整保留的权限策略可能延后加载。")
                                    if let threadID = model.threadID { Text("已核对对话：\(threadID)").textSelection(.enabled) }
                                }
                                .font(.callout).foregroundStyle(.secondary).padding(.top, 10)
                            }
                            .font(.callout)
                        }
                    }
                }
                .padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 13) {
                if let error = model.error {
                    HStack {
                        InlineMessage(text: error, symbol: "exclamationmark.triangle", color: .red)
                        if model.project != nil {
                            Button(model.targetVerificationFailed ? "使用上次定位" : "重新读取") { model.reload() }
                                .disabled(model.saving || model.loading || model.identifying)
                        }
                    }
                }
                if model.focusPermissionRequired {
                    Button("打开辅助功能设置…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                if let feedback = model.feedback, !model.dirty { InlineMessage(text: feedback, symbol: "checkmark.circle", color: .green) }
                HStack {
                    Text(model.saving ? "正在保存设置…" : (model.loading ? "正在读取设置…" : (model.dirty ? "更改尚未保存" : "没有待保存的更改")))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    if model.saving { ProgressView().controlSize(.small) }
                    Button("关闭", action: close).keyboardShortcut(.cancelAction).disabled(model.saving)
                    Button("保存设置") { model.save() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!model.canSave)
                }
            }
            .padding(.horizontal, 30).padding(.vertical, 18)
        }
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.targetVerificationFailed ? "上次定位（本次识别未成功）" : (model.threadID == nil ? "上次选择的项目" : "已锁定对话 · \(String(model.threadID!.prefix(8)))"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if model.threadID != nil {
                    Picker("修改范围", selection: Binding(get: { model.scope }, set: { model.selectScope($0) })) {
                        ForEach(ContextScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu).fixedSize().disabled(model.saving || model.loading || model.identifying)
                }
            }
            if model.threadID != nil {
                if let title = model.threadTitle {
                    Text(title).font(.headline).lineLimit(2).textSelection(.enabled).help(title)
                }
                Text("定位来源：\(model.targetOrigin.rawValue)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder").font(.system(size: 24)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(URL(fileURLWithPath: model.project ?? "").lastPathComponent)
                        .font(.system(size: 17, weight: .semibold))
                    Text(model.project ?? "").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled).help(model.project ?? "")
                }
            }
            Text(model.scope == .thread ? "对话级设置：不会修改此项目下的其他对话。" : "项目级设置：影响此项目下未单独覆盖的全部对话。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
        }
    }

    private func strategy(_ status: ProjectContextStatus) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("上下文策略").font(.system(size: 15, weight: .semibold))
            Picker("上下文策略", selection: $model.mode) {
                ForEach(ContextMode.allCases) { mode in
                    Text(mode.title).tag(mode).disabled(mode == .adaptive && !status.adaptive_available)
                }
            }
            .pickerStyle(.segmented).labelsHidden().disabled(model.saving)
            VStack(alignment: .leading, spacing: 13) {
                Label(detailTitle, systemImage: model.mode.symbol).font(.system(size: 16, weight: .semibold))
                Text(detailDescription).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.mode == .custom {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        TextField("例如 485", text: $model.input)
                            .font(.system(size: 20, weight: .medium).monospacedDigit())
                            .textFieldStyle(.roundedBorder).frame(width: 170)
                            .accessibilityLabel("自定义上下文，单位 K tokens").disabled(model.saving)
                        Text("K tokens").foregroundStyle(.secondary)
                    }
                    if let validation = model.validation { InlineMessage(text: validation, symbol: "exclamationmark.circle", color: .red) }
                    else { Text(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "留空保存，将清除当前范围的覆盖并继承默认。" : "1 K = 1,000 tokens。最终窗口以运行反馈为准。")
                        .font(.caption).foregroundStyle(.secondary) }
                } else if model.mode == .adaptive {
                    HStack(alignment: .top, spacing: 16) {
                        adaptiveField("两次触发线（%）", input: $model.lowerThreshold, placeholder: model.thresholdPlaceholder(true))
                        adaptiveField("一次触发线（%）", input: $model.upperThreshold, placeholder: model.thresholdPlaceholder(false))
                    }
                    if !model.lowerThreshold.isEmpty || !model.upperThreshold.isEmpty {
                        Text("已保存的阈值会覆盖灰色默认值；点击恢复默认并保存，才会改用新默认。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(0..<3) { index in
                            adaptiveField(["初始档（K）", "中间档（K）", "上限档（K）"][index],
                                input: $model.tierInputs[index], placeholder: model.tierPlaceholder(index))
                        }
                    }
                    Text("灰色数字为默认参考，留空按默认生效。初始与上限跟随官方；中间档取当前初始与上限的算术中点。输入值仍受官方模型上限约束。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let preview = status.adaptive_preview {
                        Text("档位来源：官方本地模型目录 · \(preview.model)").font(.caption).foregroundStyle(.secondary)
                    } else if let reason = status.adaptive_preview_reason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("从自定义切回自适应，会从初始档重新开始，不沿用自定义数值或历史升档。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("恢复默认阈值与官方档位") {
                        model.lowerThreshold = ""; model.upperThreshold = ""; model.tierInputs = ["", "", ""]
                    }.disabled(model.saving || model.repairingRuntime)
                    if let validation = model.validation { InlineMessage(text: validation, symbol: "exclamationmark.circle", color: .red) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.mode)
            if !status.trusted { InlineMessage(text: "此项目尚未受信任。请先在 Codex 中打开并信任，然后重新选择。", symbol: "lock", color: .orange) }
            if !status.inherited.isEmpty {
                InlineMessage(text: "项目、上级或全局仍有上下文覆盖；恢复默认会继承它们。", symbol: "info.circle", color: .orange)
            }
        }
    }

    private func adaptiveField(_ title: String, input: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: input).textFieldStyle(.roundedBorder).accessibilityLabel(title)
                .disabled(model.saving || model.repairingRuntime)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activation(_ status: ProjectContextStatus) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(status.adaptive_available ? "支持下一轮生效" : (model.scope == .thread ? "对话级组件不可用" : "重启后生效"), systemImage: "clock")
                .font(.subheadline.weight(.medium))
            Text(ContextActivationCopy.initial + "\n" + ContextActivationCopy.nextTurn)
                .font(.caption).foregroundStyle(.secondary)
            if let window = model.observedWindow {
                HStack { Text("最近运行窗口"); Spacer(); Text("\(window.formatted()) tokens").monospacedDigit() }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let target = model.observedTarget {
                HStack { Text("最近软预算"); Spacer(); Text("\(target.formatted()) tokens").monospacedDigit() }
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("本地压缩观测与推荐") {
                CompactionStatisticsView(statistics: model.compactionStatistics)
                if let error = model.statisticsError { Text(error).font(.caption).foregroundStyle(.orange) }
                Button("刷新压缩统计") { model.refreshStatistics() }.disabled(model.statisticsBusy)
            }
        }
    }

    private var detailTitle: String {
        switch model.mode { case .default: return "由 Codex 决定"; case .adaptive: return "随任务逐级调整"; case .custom: return "指定你需要的预算" }
    }
    private var detailDescription: String {
        switch model.mode {
        case .default: return model.scope == .thread ? "清除本对话的覆盖，继承项目、上级与官方默认。不固定任何上下文数值。" : "移除项目覆盖，跟随官方模型与已有上级设置。不固定任何上下文数值。"
        case .adaptive: return "保留比例达到条件时升档；连续两次成功自动压缩后的保留量低于相邻低档预算 × 两次触发线时，降一级。手动、失败或未知样本打断降档计数；新档位在下一安全启动边界加载。"
        case .custom: return "输入整数 K。留空恢复默认，不修改官方压缩模型或推理强度。"
        }
    }
}

struct CompactionStatisticsView: View {
    let statistics: CompactionStatistics?
    private func tokens(_ value: Int64?) -> String {
        value.map { (Double($0) / 1000).formatted(.number.precision(.fractionLength(1))) + "K" } ?? "未知"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("只读本地日志重建长度，只保存数字，不保存或上传正文、代码或凭据。最近报告用量不等于内核触发计数：另估算新增工具结果与历史加密推理。服务端是否已计入历史推理未报告，因此同时列出不补计 / 补计两种估算；不是精确值或严格置信区间。")
            if let statistics {
                Text("\(statistics.model) · 当前已保存预算 \(tokens(statistics.budget))")
                if let error = statistics.error { Text(error).foregroundStyle(.orange) }
                if statistics.groups.isEmpty { Text("尚无压缩样本。运行组件加载后开始记录，不倒填或伪造历史。") }
                ForEach(Array(statistics.groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.percent.map { "\($0)%设置目标（不是触发用量实测）" } ?? "官方默认（触发线未报告）").fontWeight(.semibold)
                        Text(group.scope == "body_after_prefix" ? "完整窗口检查" : (group.scope == "total" ? "总量触发检查" : "检查范围未报告"))
                        Text("自动成功 \(group.automatic) 次 · 有报告 \(group.reported_available ?? 0) 次 · 可重建 \(group.measured) 次 · 未知 \(group.unknown) 次 · 手动 \(group.manual) 次 · 失败/未完成 \(group.failed) 次")
                        Text("估算预算越线率（补计历史推理）：\(group.observed_rate.map { ($0 * 100).formatted(.number.precision(.fractionLength(1))) + "%" } ?? "未知")（\(group.crossed)/\(group.measured)） · 估算越线均值 \(tokens(group.mean_excess)) · P95 \(tokens(group.p95_excess))")
                        Text("不补计历史推理的估算越线率：\(group.uncompensated_rate.map { ($0 * 100).formatted(.number.precision(.fractionLength(1))) + "%" } ?? "未知")。预算越线指超过保存预算，不等于超过设置目标。")
                        Text("估算设置目标超过量P95 \(tokens(group.trigger_p95_excess))（\(group.trigger_crossed ?? 0)/\(group.trigger_measured ?? 0)，含推理补计）；不是实际触发原因的归因。")
                        if let recommended = group.recommended_percent {
                            Text("估算参考建议 \(recommended)%：按含推理补计估算的目标超过量P95预留空间。依赖补计假设，不代表实际越线概率，不保证未来不越线，不自动修改设置。")
                        } else { Text("至少10条可重建样本且覆盖率达80%才给估算建议；未知样本不算成未越线，未重建时不展示0%。") }
                    }
                }
                ForEach(Array(statistics.recent.prefix(5).enumerated()), id: \.offset) { _, sample in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Date(timeIntervalSince1970: Double(sample.at) / 1000).formatted(date: .omitted, time: .standard)) · 报告前输入 \(tokens(sample.before_input)) / 合计 \(tokens(sample.before_total)) → 报告后合计 \(tokens(sample.after_total)) · \(Double(sample.duration_ms) / 1000, specifier: "%.1f")秒\(sample.manual ? " · 手动" : "") · \(sample.status == "completed" ? "完成" : "失败/未完成")")
                        if let accounting = sample.accounting {
                            Text("重建估算约 \(tokens(accounting.lower_total))–\(tokens(accounting.upper_total))（不补计 / 补计历史推理） · 新增本地结果约 \(tokens(accounting.pending_local)) · 历史推理约 \(tokens(accounting.history_reasoning))；未取得内核精确计数。")
                        } else { Text("重建估算未知：本地日志不足或包含无法重建的项目；报告值保留，但不参与估算统计。") }
                    }
                }
            } else { Text("统计尚未读取，请刷新。") }
        }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
    }
}

struct InlineMessage: View {
    let text: String
    let symbol: String
    let color: Color
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(color) }
            .font(.caption).foregroundStyle(.primary).accessibilityElement(children: .combine)
    }
}
