import Foundation
import SwiftUI

enum CompanionPage: String, CaseIterable, Identifiable {
    case context = "上下文"
    case usage = "用量概览"
    var id: String { rawValue }
    var symbol: String { self == .context ? "slider.horizontal.3" : "chart.bar.xaxis" }
}

enum ContextMode: String, CaseIterable, Identifiable {
    case `default`, adaptive, custom
    var id: String { rawValue }
    var title: String {
        switch self { case .default: return "官方默认"; case .adaptive: return "自适应"; case .custom: return "自定义" }
    }
    var symbol: String {
        switch self { case .default: return "arrow.counterclockwise"; case .adaptive: return "arrow.up.right"; case .custom: return "number" }
    }
}

enum ContextScope: String, CaseIterable, Identifiable {
    case thread = "仅此对话", project = "整个项目"
    var id: String { rawValue }
}

enum ContextTargetOrigin: String {
    case focused = "窗口焦点", link = "深度链接", manual = "手动选择"
}

enum ContextActivationCopy {
    static let initial = "首次安装并启用工具，或更新运行组件后，需完整退出并重新打开整个 Codex 一次；不是每个对话都要重启。"
    static let nextTurn = "接入后，设置切换和自动升档在下一轮对话开始前加载，无需重启；不打断当前回复。"
    static let saved = "设置已保存，将在下一轮尝试加载；请以运行窗口确认实际生效。"
}

@MainActor
final class ContextSettingsModel: ObservableObject {
    @Published var page: CompanionPage = .context
    @Published var project: String?
    @Published var status: ProjectContextStatus?
    @Published var mode: ContextMode = .default
    @Published var input = ""
    @Published var lowerThreshold = ""
    @Published var upperThreshold = ""
    @Published var tierInputs = ["", "", ""]
    @Published var repairingRuntime = false
    @Published var runtimeReason: String?
    @Published var loading = false
    @Published var saving = false
    @Published var error: String?
    @Published var feedback: String?
    @Published var threadID: String?
    @Published var threadTitle: String?
    @Published var observedWindow: Int64?
    @Published var observedTarget: Int64?
    @Published var integrationPending = false
    @Published var scope: ContextScope = .project
    @Published var targetLink = ""
    @Published var identifying = false
    @Published var targetVerificationFailed = false
    @Published var focusPermissionRequired = false
    @Published var targetOrigin: ContextTargetOrigin = .manual
    private var generation = UUID()
    private var savedMode: ContextMode = .default
    private var savedInput = ""
    private var savedAdaptive: AdaptiveOptions?

    func adaptiveOptions() throws -> AdaptiveOptions {
        guard let defaults = status?.adaptive_defaults else { throw FocusedContextTarget.failure("默认参数尚未读取，请重新读取设置。") }
        return try AdaptiveOptions.parse(lower: lowerThreshold, upper: upperThreshold, tiers: tierInputs, defaults: defaults)
    }

    func thresholdPlaceholder(_ lower: Bool) -> String {
        guard let defaults = status?.adaptive_defaults else { return "读取中…" }
        return (lower ? defaults.lower_percent : defaults.upper_percent).formatted(.number)
    }

    func tierPlaceholder(_ index: Int) -> String {
        guard let preview = status?.adaptive_preview else { return "未读取官方值" }
        let values = preview.display_tiers ?? (preview.tiers.count == 3 ? preview.tiers : [])
        guard values.indices.contains(index) else { return "未读取官方值" }
        return (Double(values[index]) / 1000).formatted(.number.grouping(.never))
    }

    var validation: String? {
        if mode == .adaptive {
            do { _ = try adaptiveOptions(); return nil } catch { return error.localizedDescription }
        }
        guard mode == .custom else { return nil }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        let digits = value.lowercased().hasSuffix("k") ? String(value.dropLast()) : value
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let amount = Int64(digits), amount > 0, amount <= Int64.max / 1000 else {
            return "请输入正整数 K，例如 485；留空恢复默认。"
        }
        return nil
    }
    var dirty: Bool { mode != savedMode || (mode == .custom && input != savedInput) || (mode == .adaptive && (try? adaptiveOptions()) != savedAdaptive) }
    var canSave: Bool {
        status?.trusted == true && !loading && !saving && !identifying && !repairingRuntime && !targetVerificationFailed && validation == nil && (dirty || integrationPending)
            && (mode != .adaptive || status?.adaptive_available == true)
            && (scope != .thread || (threadID != nil && status?.adaptive_available == true))
    }

    func load(project: String, threadID: String?, observedWindow: Int64?, observedTarget: Int64?, scope: ContextScope? = nil, origin: ContextTargetOrigin? = nil, title: String? = nil, selectedMode: ContextMode? = nil) {
        guard !saving else { return }
        let request = UUID()
        generation = request
        self.project = project
        self.threadID = threadID
        self.threadTitle = threadID == nil ? nil : title
        targetVerificationFailed = false
        focusPermissionRequired = false
        targetOrigin = threadID == nil ? .manual : (origin ?? targetOrigin)
        self.scope = threadID == nil ? .project : (scope ?? .thread)
        let arguments = self.scope == .thread ? ["thread-status", project, threadID!] : ["status", project]
        self.observedWindow = observedWindow
        self.observedTarget = observedTarget
        status = nil
        error = nil
        feedback = nil
        loading = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try ContextBackend.run(arguments) }.value
                guard generation == request else { return }
                adopt(result)
                if let selectedMode { mode = selectedMode }
                integrationPending = false
                UserDefaults.standard.set(result.root, forKey: "contextSettings.lastProject")
            } catch {
                guard generation == request else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    func failTarget(_ message: String) {
        targetVerificationFailed = true
        error = message + (project == nil ? "" : " 上方保留的是上次定位，不是本次识别结果。")
        feedback = nil
    }

    func selectScope(_ selected: ContextScope) {
        guard let project, !saving, !loading, !identifying else { return }
        load(project: project, threadID: threadID, observedWindow: observedWindow, observedTarget: observedTarget, scope: selected, title: threadTitle)
    }

    func reload() {
        guard let project, !saving else { return }
        load(project: project, threadID: threadID, observedWindow: observedWindow, observedTarget: observedTarget, scope: scope, title: threadTitle)
    }

    private func adopt(_ result: ProjectContextStatus) {
        status = result
        project = result.root
        mode = result.adaptive ? .adaptive : (result.window == nil ? .default : .custom)
        input = result.window.map { String($0 / 1000) } ?? ""
        savedMode = mode
        savedInput = input
        savedAdaptive = result.adaptive_options ?? result.adaptive_defaults
        lowerThreshold = savedAdaptive?.lower_percent == result.adaptive_defaults?.lower_percent ? "" : savedAdaptive.map { String($0.lower_percent) } ?? ""
        upperThreshold = savedAdaptive?.upper_percent == result.adaptive_defaults?.upper_percent ? "" : savedAdaptive.map { String($0.upper_percent) } ?? ""
        tierInputs = savedAdaptive?.tiers.map { $0.map { String($0 / 1000) } ?? "" } ?? ["", "", ""]
        runtimeReason = result.adaptive_available ? nil : result.adaptive_reason ?? "运行组件未完成接入。"
    }

    func inspectRuntime() {
        let backend = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexContextTool/backend").path
        guard FileManager.default.isExecutableFile(atPath: backend) else { runtimeReason = "尚未完成组件接入。拖入应用后，请在这里完成一次接入；重启不会补装组件。"; return }
        if URL(fileURLWithPath: backend).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            != Bundle.main.resourceURL?.resolvingSymlinksInPath() {
            runtimeReason = "运行组件属于另一份应用安装，请为当前应用完成接入 / 重新验证。"
            return
        }
        Task {
            do {
                let data = try await Task.detached { try LocalCommand.run(backend, ["--context-capability"]) }.value
                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                runtimeReason = result?["adaptive"] as? Bool == true ? nil : result?["reason"] as? String ?? "请重新验证组件接入。"
            } catch { runtimeReason = "组件检查未完成，请重新验证接入。" }
        }
    }

    func repairRuntime() {
        guard !repairingRuntime, !saving, !loading, !identifying else { return }
        guard !Bundle.main.bundleURL.path.hasPrefix("/Volumes/") else { error = "请先把应用拖入 Applications，再从应用目录打开并完成接入。"; return }
        repairingRuntime = true
        error = nil
        Task {
            defer { repairingRuntime = false }
            do {
                let bundle = Bundle.main.bundleURL.path
                guard let script = Bundle.main.path(forResource: "install_local", ofType: "py") else { throw FocusedContextTarget.failure("安装资源缺失，请重新下载完整应用。") }
                _ = try await Task.detached(priority: .userInitiated) {
                    try LocalCommand.run(ContextBackend.python(), ["-B", script, bundle, "--integrate-only"], timeout: 150)
                }.value
                runtimeReason = nil
                if project != nil { reload() }
                feedback = "组件接入完成。首次接入或更新运行组件后，请完整重启 Codex 一次；不是每个对话都要重启。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func save() {
        guard canSave, let status else { return }
        let root = status.root
        let revision = status.revision
        let selectedMode = mode.rawValue
        let value = mode == .custom ? input : ""
        let options = (try? adaptiveOptions()) ?? savedAdaptive
        guard let encoded = try? JSONEncoder().encode(options), let adaptiveJSON = String(data: encoded, encoding: .utf8) else { return }
        let arguments = scope == .thread && threadID != nil
            ? ["thread-save", root, threadID!, value, revision, selectedMode, adaptiveJSON]
            : ["save", root, value, revision, selectedMode, adaptiveJSON]
        saving = true
        error = nil
        feedback = nil
        Task {
            do {
                let saved = try await Task.detached(priority: .userInitiated) {
                    try ContextBackend.run(arguments)
                }.value
                adopt(saved)
                if saved.adaptive_available {
                    let executable = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Application Support/CodexContextTool/backend").path
                    do {
                        _ = try await Task.detached(priority: .userInitiated) {
                            try LocalCommand.run(executable, ["--enable-integration"])
                        }.value
                    } catch {
                        integrationPending = true
                        self.error = "设置已保存，但启动接入未完成。请重试或重新安装工具。"
                        saving = false
                        return
                    }
                }
                integrationPending = false
                feedback = saved.adaptive_available ? ContextActivationCopy.saved : "设置已保存，但下一轮加载组件不可用；请重新安装或恢复接入。"
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
