import AppKit
import Foundation
import SwiftUI
import CodexTokenCore

struct ProjectContextStatus: Decodable, Sendable {
    struct Inherited: Decodable, Sendable {
        let path: String
        let values: [String: Int64]
    }
    let root: String
    let path: String
    let revision: String
    let window: Int64?
    let compact: Int64?
    let adaptive: Bool
    let adaptive_available: Bool
    let trusted: Bool
    let inherited: [Inherited]
    let scope: String?
    let `override`: Bool?
}

enum ContextBackend {
    static func run(_ arguments: [String]) throws -> ProjectContextStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3",
                          "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let script = Bundle.main.path(forResource: "context_config", ofType: "py") else {
            throw NSError(domain: "Context", code: 1, userInfo: [NSLocalizedDescriptionKey: "需要 Python 3.11+，或 Codex 自带的 Python 运行时。"])
        }
        let data = try LocalCommand.run(python, ["-B", script] + arguments)
        return try JSONDecoder().decode(ProjectContextStatus.self, from: data)
    }
}

enum ContextTarget {
    struct Located: Sendable {
        let project: String
        let threadID: String
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

    func present(project: String, threadID: String?, observedWindow: Int64?, observedTarget: Int64? = nil, origin: ContextTargetOrigin = .link) {
        showWindow()
        guard !model.saving else { return }
        model.page = .context
        model.load(project: project, threadID: threadID, observedWindow: observedWindow, observedTarget: observedTarget, origin: origin)
    }

    func chooseProject() {
        showWindow()
        if model.project == nil, let last = UserDefaults.standard.string(forKey: "contextSettings.lastProject"),
           FileManager.default.fileExists(atPath: last) {
            model.load(project: last, threadID: nil, observedWindow: nil, observedTarget: nil, scope: .project)
        }
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
                present(project: target.project, threadID: target.threadID, observedWindow: nil)
            } catch {
                model.failTarget(error.localizedDescription)
            }
            model.identifying = false
        }
    }

    private func showWindow() {
        if windowController == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 710),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Codex 上下文"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 780, height: 650)
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
        NSApp.activate(ignoringOtherApps: true)
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
