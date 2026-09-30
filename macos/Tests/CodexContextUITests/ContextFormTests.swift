import XCTest
import AppKit
@testable import CodexTokenOverlayMac

final class ContextFormTests: XCTestCase {
    @MainActor
    func testNativeEditingShortcutsUseTheFirstResponderAndAutomaticValidation() {
        let menu = NativeEditingMenu.make()
        let editing = menu.items.first(where: { $0.title == "编辑" })!.submenu!
        XCTAssertTrue(editing.autoenablesItems)
        for (action, shortcut) in [("cut:", "x"), ("copy:", "c"), ("paste:", "v"), ("selectAll:", "a"), ("undo:", "z")] {
            let item = editing.items.first(where: { $0.action == NSSelectorFromString(action) })!
            XCTAssertEqual(item.keyEquivalent, shortcut)
            XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
            XCTAssertNil(item.target)
        }
        let redo = editing.items.first(where: { $0.action == NSSelectorFromString("redo:") })!
        XCTAssertEqual(redo.keyEquivalentModifierMask, [.command, .shift])
    }

    func testInitialActivationCopyClearlyScopesRestartToCodexInstallation() {
        XCTAssertTrue(ContextActivationCopy.initial.contains("整个 Codex"))
        XCTAssertTrue(ContextActivationCopy.initial.contains("不是每个对话"))
        XCTAssertTrue(ContextActivationCopy.nextTurn.contains("下一轮"))
        XCTAssertTrue(ContextActivationCopy.saved.contains("运行窗口确认实际生效"))
        XCTAssertFalse(ContextActivationCopy.saved.contains("已生效"))
    }

    func testDeepLinksRequireExactLocalThreadAndMatchingRecord() throws {
        let identifier = "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(try ContextTarget.threadID(link: "codex://threads/\(identifier)?view=review"), identifier)
        for link in ["codex://threads/new", "https://example.com/\(identifier)",
                     "codex://threads/\(identifier)?hostId=remote", "codex://threads/\(identifier)/other"] {
            XCTAssertThrowsError(try ContextTarget.threadID(link: link))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("rollout-\(identifier).jsonl")
        let data = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(identifier)\",\"cwd\":\"/project\"}}\n".utf8)
        try data.write(to: log)
        XCTAssertThrowsError(try ContextTarget.locate(link: "codex://threads/\(identifier)", sessionRoots: [directory.path], requireDesktopRoot: true))
        XCTAssertEqual(try ContextTarget.locate(link: "codex://threads/\(identifier)", sessionRoots: [directory.path]).project, "/project")
        let desktop = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(identifier)\",\"cwd\":\"/project\",\"originator\":\"Codex Desktop\",\"source\":\"vscode\"}}\n".utf8)
        try desktop.write(to: log)
        XCTAssertEqual(try ContextTarget.locate(link: "codex://threads/\(identifier)", sessionRoots: [directory.path], requireDesktopRoot: true).project, "/project")
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"different\",\"cwd\":\"/wrong\"}}\n".utf8).write(to: log)
        XCTAssertThrowsError(try ContextTarget.locate(link: "codex://threads/\(identifier)", sessionRoots: [directory.path]))
    }

    @MainActor
    func testFailedRecognitionLabelsPreviousTargetAndBlocksSave() async throws {
        let model = ContextSettingsModel()
        model.project = "/project"
        model.status = try JSONDecoder().decode(ProjectContextStatus.self, from: Data("{\"root\":\"/project\",\"path\":\"/project/.codex/config.toml\",\"revision\":\"x\",\"adaptive\":false,\"adaptive_available\":true,\"trusted\":true,\"inherited\":[]}".utf8))
        model.mode = .custom
        model.input = "485"
        XCTAssertTrue(model.canSave)
        model.failTarget("Cannot identify")
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(model.project, "/project")
        XCTAssertTrue(model.error!.contains("上次定位"))
    }
    @MainActor
    func testCustomValidationAndDefaultRestoration() async {
        let model = ContextSettingsModel()
        model.mode = .custom
        for value in ["", "485", "485K", " 600k "] {
            model.input = value
            XCTAssertNil(model.validation, value)
        }
        for value in ["0", "-1", "4.85", "K", "abc", "9223372036854776"] {
            model.input = value
            XCTAssertNotNil(model.validation, value)
        }
        model.mode = .default
        XCTAssertNil(model.validation)
        XCTAssertFalse(model.dirty)
    }

    @MainActor
    func testSaveEligibilityAndPendingIntegrationRetry() async throws {
        let raw = Data("""
        {"root":"/project","path":"/project/.codex/config.toml","revision":"first",
        "adaptive":false,"adaptive_available":true,"trusted":true,"inherited":[]}
        """.utf8)
        let model = ContextSettingsModel()
        model.status = try JSONDecoder().decode(ProjectContextStatus.self, from: raw)
        XCTAssertFalse(model.canSave)
        model.mode = .custom
        model.input = "485"
        XCTAssertTrue(model.canSave)
        model.targetVerificationFailed = true
        XCTAssertFalse(model.canSave)
        model.targetVerificationFailed = false
        model.saving = true
        XCTAssertFalse(model.canSave)
        model.saving = false
        model.mode = .default
        model.input = ""
        model.integrationPending = true
        XCTAssertTrue(model.canSave)
        model.loading = true
        XCTAssertFalse(model.canSave)
    }
}
