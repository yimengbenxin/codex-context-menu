import AppKit
import Foundation
import SwiftUI
import OSLog
import CodexTokenCore

struct CompactionStatistics: Decodable, Sendable {
    struct Group: Decodable, Sendable {
        let percent: Int?
        let scope: String?
        let samples: Int
        let automatic: Int
        let manual: Int
        let failed: Int
        let measured: Int
        let unknown: Int
        let crossed: Int
        let observed_rate: Double?
        let mean_excess: Int64?
        let p95_excess: Int64?
        let trigger_crossed: Int?
        let trigger_measured: Int?
        let trigger_p95_excess: Int64?
        let recommended_percent: Int?
        let reported_available: Int?
        let uncompensated_rate: Double?
    }
    struct Sample: Decodable, Sendable {
        struct Accounting: Decodable, Sendable {
            let basis: String
            let pending_local: Int64
            let history_reasoning: Int64
            let lower_total: Int64
            let upper_total: Int64
        }
        let at: Int64
        let percent: Int?
        let before_input: Int64?
        let before_total: Int64?
        let after_total: Int64?
        let duration_ms: Int64
        let status: String
        let manual: Bool
        let accounting: Accounting?
    }
    let model: String
    let budget: Int64
    let groups: [Group]
    let recent: [Sample]
    let error: String?
}

struct ProjectContextStatus: Decodable, Sendable {
    struct Preview: Decodable, Sendable {
        struct Compaction: Decodable, Sendable {
            let budget: Int64
            let maximum_percent: Int
        }
        let model: String
        let tiers: [Int64]
        let maximum: Int64
        let display_tiers: [Int64]?
        let percent: Int?
        let compaction: Compaction?
    }
    struct Inherited: Decodable, Sendable {
        let path: String
        let values: [String: Int64]
    }
    let root: String
    let path: String
    let revision: String
    let window: Int64?
    let compact: Int64?
    let compaction_percent: Int?
    let compaction_statistics: CompactionStatistics?
    let adaptive: Bool
    let adaptive_available: Bool
    let adaptive_reason: String?
    let adaptive_options: AdaptiveOptions?
    let adaptive_defaults: AdaptiveOptions?
    let adaptive_preview: Preview?
    let adaptive_preview_reason: String?
    let trusted: Bool
    let inherited: [Inherited]
    let scope: String?
    let `override`: Bool?
}

enum ContextBackend {
    static func python() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [ProcessInfo.processInfo.environment["CODEX_CONTEXT_PYTHON"] ?? "",
                          "\(home)/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3",
                          "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if let data = try? LocalCommand.run(candidate, ["-c", "import sys; print(sys.version_info >= (3, 11))"], timeout: 5),
               String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "True" { return candidate }
        }
        throw NSError(domain: "Context", code: 1, userInfo: [NSLocalizedDescriptionKey: "需要 Python 3.11+，或 Codex 自带的 Python 运行时。"])
    }

    static func run(_ arguments: [String]) throws -> ProjectContextStatus {
        let python = try python()
        guard let script = Bundle.main.path(forResource: "context_config", ofType: "py") else { throw FocusedContextTarget.failure("应用资源不完整，请重新下载。") }
        let data = try LocalCommand.run(python, ["-B", script] + arguments + ["--preview"])
        return try JSONDecoder().decode(ProjectContextStatus.self, from: data)
    }
}

enum ContextTarget {
    struct Located: Sendable {
        let project: String
        let threadID: String
    }

    static func locate(focusedTitle: String?, sessionRoots: [String]? = nil,
                       databasePath: String = SessionPathResolver.resolveCodexHome() + "/state_5.sqlite") throws -> Located {
        guard let focusedTitle else { throw FocusedContextTarget.failure("需要辅助功能权限才能核对窗口焦点。请授权后识别，或粘贴深度链接；不会按后台订阅猜目标。") }
        let identifier = try FocusedContextTarget.threadID(title: focusedTitle, databasePath: databasePath)
        return try locate(link: "codex://threads/\(identifier)", sessionRoots: sessionRoots, requireDesktopRoot: true)
    }

    static func threadID(link: String) throws -> String {
        guard let url = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "codex", url.host?.lowercased() == "threads",
              url.user == nil, url.password == nil, url.port == nil,
              !(url.queryItems ?? []).contains(where: { $0.name == "hostId" && $0.value != "local" }),
              url.path.split(separator: "/").count == 1,
              let identifier = UUID(uuidString: String(url.path.dropFirst())) else {
            throw NSError(domain: "Context", code: 4, userInfo: [NSLocalizedDescriptionKey: "请粘贴本机对话链接 codex://threads/对话ID；不支持远程或分享链接。"])
        }
        return identifier.uuidString.lowercased()
    }

    static func locate(link: String, sessionRoots: [String]? = nil, requireDesktopRoot: Bool = false) throws -> Located {
        let identifier = try threadID(link: link)
        let home = SessionPathResolver.resolveCodexHome()
        let roots = sessionRoots ?? ["\(home)/sessions", "\(home)/archived_sessions"]
        var located: Located?
        for root in roots {
            guard let files = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in files where file.lastPathComponent.lowercased().hasSuffix("\(identifier).jsonl") {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let root = try project(logPath: file.path, threadID: identifier, requireDesktopRoot: requireDesktopRoot)
                guard located == nil else {
                    throw NSError(domain: "Context", code: 5, userInfo: [NSLocalizedDescriptionKey: "发现重复的本地对话记录，未猜测目标。"])
                }
                located = Located(project: root, threadID: identifier)
            }
        }
        guard let located else {
            throw NSError(domain: "Context", code: 6, userInfo: [NSLocalizedDescriptionKey: "未找到这个链接对应的本地对话。请确认链接来自本机 Codex。"])
        }
        return located
    }

    static func project(logPath: String, threadID: String, requireDesktopRoot: Bool = false) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: logPath))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 256 * 1024) ?? Data()
        guard let newline = data.firstIndex(of: 10),
              let record = try JSONSerialization.jsonObject(with: data.prefix(upTo: newline)) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any],
              (payload["id"] as? String)?.lowercased() == threadID.lowercased(),
              let cwd = payload["cwd"] as? String, cwd.hasPrefix("/") else {
            throw NSError(domain: "Context", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法核对当前对话的项目目录，请手动选择项目。"])
        }
        if requireDesktopRoot && !SessionOrigin.isDesktopRoot(originator: payload["originator"] as? String, source: payload["source"] as? String) {
            throw NSError(domain: "Context", code: 7, userInfo: [NSLocalizedDescriptionKey: "当前订阅不是可核对的桌面主对话，请用目标对话的深度链接定位。"])
        }
        return cwd
    }
}

@MainActor
final class ContextSettingsController: NSObject, NSWindowDelegate {
    let model = ContextSettingsModel()
    let usage = UsageModel()
    var identifyCurrent: (() -> Void)?
    private var windowController: NSWindowController?
    private var pickerOpen = false
    private let windowLogger = Logger(subsystem: "local.wen.CodexContextMenu", category: "window")

    func loadTarget(project: String, threadID: String?, observedWindow: Int64?, observedTarget: Int64? = nil, origin: ContextTargetOrigin = .link, title: String? = nil) {
        guard !model.saving else { return }
        model.page = .context
        model.load(project: project, threadID: threadID, observedWindow: observedWindow, observedTarget: observedTarget, origin: origin, title: title)
    }

    func chooseProject() {
        model.page = .context
        showWindow(source: "context-command")
    }

    func showUsage() {
        model.page = .usage
        showWindow(source: "usage-command")
    }

    func identify() {
        guard !model.saving, !model.loading, !model.identifying else { return }
        identifyCurrent?()
    }

    func locateLink() {
        guard !model.saving, !model.loading, !model.identifying else { return }
        let link = model.targetLink
        model.identifying = true
        model.error = nil
        Task {
            do {
                let target = try await Task.detached(priority: .userInitiated) { try ContextTarget.locate(link: link) }.value
                loadTarget(project: target.project, threadID: target.threadID, observedWindow: nil)
            } catch {
                model.failTarget(error.localizedDescription)
            }
            model.identifying = false
        }
    }

    private func showWindow(source: String) {
        windowLogger.info("Explicit window open: \(source, privacy: .public)")
        if windowController == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Codex 上下文"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 800, height: 540)
            window.delegate = self
            window.setFrameAutosaveName("CodexContextSettings")
            window.contentView = NSHostingView(rootView: CompanionView(model: model, usage: usage,
                chooseProject: { [weak self] in self?.selectFolder() }, identify: { [weak self] in self?.identify() },
                locateLink: { [weak self] in self?.locateLink() }, close: { [weak self] in self?.windowController?.close() }))
            window.center()
            windowController = NSWindowController(window: window)
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func selectFolder() {
        guard !pickerOpen, !model.saving, let window = windowController?.window else { return }
        pickerOpen = true
        let picker = NSOpenPanel()
        picker.title = "选择要调整上下文的项目"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        if let project = model.project { picker.directoryURL = URL(fileURLWithPath: project) }
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.pickerOpen = false
            if response == .OK, let project = picker.url {
                self.model.load(project: project.path, threadID: nil, observedWindow: nil, observedTarget: nil, scope: .project)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.saving }
}
