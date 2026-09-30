import AppKit
import ApplicationServices
import SQLite3
import CodexTokenCore

enum FocusedContextTarget {
    struct Focus: Equatable {
        let processID: pid_t
        let window: AXUIElement
        let title: String

        static func == (left: Focus, right: Focus) -> Bool {
            left.processID == right.processID && left.title == right.title && CFEqual(left.window, right.window)
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "ContextFocus", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @MainActor
    static func capture(requestPermission: Bool = false) throws -> Focus? {
        guard AXIsProcessTrusted() else {
            if requestPermission {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            return nil
        }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.openai.codex" }
        let front = NSWorkspace.shared.frontmostApplication
        guard let app = apps.first(where: { $0.processIdentifier == front?.processIdentifier }) ?? (apps.count == 1 ? apps.first : nil) else {
            throw failure("无法确定 Codex 进程。请先点选目标 Codex 窗口，再识别或使用深度链接。")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let window = attribute(application, kAXFocusedWindowAttribute) else {
            throw failure("未取得 Codex 焦点窗口。请先点选目标窗口再识别。")
        }
        let focused = window as! AXUIElement
        var pending = [(focused, 0)]
        var titles = Set<String>()
        var visited = 0
        while let (node, depth) = pending.popLast(), visited < 200 {
            visited += 1
            if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" {
                let address = attribute(node, kAXURLAttribute).map { String(describing: $0) } ?? ""
                if address == "app://-/index.html", let title = attribute(node, kAXTitleAttribute) as? String, !title.isEmpty {
                    titles.insert(title)
                }
                continue
            }
            if depth < 12, let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        guard pending.isEmpty, titles.count == 1, let title = titles.first else {
            throw failure("焦点窗口未提供唯一对话标题。请使用目标对话的深度链接。")
        }
        return Focus(processID: app.processIdentifier, window: focused, title: title)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func threadID(title: String, databasePath: String = SessionPathResolver.resolveCodexHome() + "/state_5.sqlite") throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw failure("无法只读查询本地对话索引。请使用深度链接。")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        let query = "SELECT id FROM threads WHERE archived = 0 AND COALESCE(NULLIF(name, ''), title) = ? LIMIT 2"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw failure("本地对话索引格式不受支持。请使用深度链接。")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, title, -1, transient) == SQLITE_OK else {
            throw failure("无法查询当前对话标题。请使用深度链接。")
        }
        var identifiers: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { identifiers.append(String(cString: text)) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw failure("读取对话索引失败，请稍后重试。") }
        guard identifiers.count == 1, let identifier = identifiers.first, let uuid = UUID(uuidString: identifier) else {
            throw failure(identifiers.count > 1 ? "存在同名对话，未猜测目标。请粘贴深度链接定位。" : "焦点标题未匹配到本地对话。请确认当前为 Codex 对话页，或使用深度链接。")
        }
        return uuid.uuidString.lowercased()
    }
}
