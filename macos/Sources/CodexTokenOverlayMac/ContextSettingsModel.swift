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
    case automatic = "自动识别", link = "深度链接", manual = "手动选择"
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
    @Published var loading = false
    @Published var saving = false
    @Published var error: String?
    @Published var feedback: String?
    @Published var threadID: String?
    @Published var observedWindow: Int64?
    @Published var observedTarget: Int64?
    @Published var integrationPending = false
    @Published var scope: ContextScope = .project
    @Published var targetLink = ""
    @Published var identifying = false
    @Published var targetVerificationFailed = false
    @Published var targetOrigin: ContextTargetOrigin = .manual
    private var generation = UUID()
    private var savedMode: ContextMode = .default
    private var savedInput = ""

    var validation: String? {
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
    var dirty: Bool { mode != savedMode || (mode == .custom && input != savedInput) }
    var canSave: Bool {
        status?.trusted == true && !loading && !saving && !identifying && !targetVerificationFailed && validation == nil && (dirty || integrationPending)
            && (mode != .adaptive || status?.adaptive_available == true)
            && (scope != .thread || (threadID != nil && status?.adaptive_available == true))
    }

    func load(project: String, threadID: String?, observedWindow: Int64?, observedTarget: Int64?, scope: ContextScope? = nil, origin: ContextTargetOrigin? = nil) {
        guard !saving else { return }
        let request = UUID()
        generation = request
        self.project = project
        self.threadID = threadID
        targetVerificationFailed = false
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
        load(project: project, threadID: threadID, observedWindow: observedWindow, observedTarget: observedTarget, scope: selected)
    }

    func reload() {
        guard let project, !saving else { return }
        load(project: project, threadID: threadID, observedWindow: observedWindow, observedTarget: observedTarget, scope: scope)
    }

    private func adopt(_ result: ProjectContextStatus) {
        status = result
        project = result.root
        mode = result.adaptive ? .adaptive : (result.window == nil ? .default : .custom)
        input = result.window.map { String($0 / 1000) } ?? ""
        savedMode = mode
        savedInput = input
    }

    func save() {
        guard canSave, let status else { return }
        let root = status.root
        let revision = status.revision
        let selectedMode = mode.rawValue
        let value = mode == .custom ? input : ""
        let arguments = scope == .thread && threadID != nil
            ? ["thread-save", root, threadID!, value, revision, selectedMode]
            : ["save", root, value, revision, selectedMode]
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
