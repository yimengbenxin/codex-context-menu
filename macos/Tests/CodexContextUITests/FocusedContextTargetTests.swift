import XCTest
import ApplicationServices
import SQLite3
import CodexTokenCore
@testable import CodexTokenOverlayMac

final class FocusedContextTargetTests: XCTestCase {
    private let first = "11111111-1111-4111-8111-111111111111"
    private let second = "22222222-2222-4222-8222-222222222222"

    private func database(_ statements: String, check: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state_5.sqlite").path
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE threads(id TEXT, title TEXT, name TEXT, archived INTEGER);" + statements, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        try check(path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    }

    func testChineseFocusedTitleSelectsItsExactThreadNotAnotherActiveThread() throws {
        try database("INSERT INTO threads VALUES('\(first)','帮我把 Codex 上下文改到 485K',NULL,0),('\(second)','另一个同时运行的对话',NULL,0);") { path in
            XCTAssertEqual(try FocusedContextTarget.threadID(title: "帮我把 Codex 上下文改到 485K", databasePath: path), first)
            XCTAssertThrowsError(try FocusedContextTarget.threadID(title: "485K", databasePath: path))
        }
    }

    func testDuplicateTitlesAreRejectedRatherThanPickingLatest() throws {
        try database("INSERT INTO threads VALUES('\(first)','相同标题',NULL,0),('\(second)','相同标题',NULL,0);") { path in
            XCTAssertThrowsError(try FocusedContextTarget.threadID(title: "相同标题", databasePath: path)) { error in
                XCTAssertTrue(error.localizedDescription.contains("同名对话"))
            }
        }
    }

    func testDisplayNameIsAuthoritativeAfterRenameAndArchivedDuplicateIsIgnored() throws {
        try database("INSERT INTO threads VALUES('\(first)','旧标题','新标题',0),('\(second)','新标题','新标题',1);") { path in
            XCTAssertEqual(try FocusedContextTarget.threadID(title: "新标题", databasePath: path), first)
            XCTAssertThrowsError(try FocusedContextTarget.threadID(title: "旧标题", databasePath: path))
        }
    }

    func testEmptyNameFallsBackToTitleAndSQLCharactersAreBoundAsText() throws {
        try database("INSERT INTO threads VALUES('\(first)','It''s a task; --','',0);") { path in
            XCTAssertEqual(try FocusedContextTarget.threadID(title: "It's a task; --", databasePath: path), first)
            XCTAssertThrowsError(try FocusedContextTarget.threadID(title: "' OR 1=1 --", databasePath: path))
        }
    }

    func testMissingDatabaseIsNotCreated() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertThrowsError(try FocusedContextTarget.threadID(title: "任务", databasePath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testMultipleSubscriptionsWithoutFocusDoNotGuess() {
        XCTAssertThrowsError(try ContextTarget.locate(focusedTitle: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("辅助功能"))
        }
    }

    func testMultipleSubscriptionsResolveFocusedTitleAndVerifyDesktopMetadata() throws {
        try database("INSERT INTO threads VALUES('\(first)','焦点任务',NULL,0),('\(second)','后台任务',NULL,0);") { path in
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            let metadata = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(first)\",\"cwd\":\"/project\",\"originator\":\"Codex Desktop\",\"source\":\"vscode\"}}\n"
            try Data(metadata.utf8).write(to: directory.appendingPathComponent("rollout-\(first).jsonl"))
            let target = try ContextTarget.locate(focusedTitle: "焦点任务", sessionRoots: [directory.path], databasePath: path)
            XCTAssertEqual(target.threadID, first)
            XCTAssertEqual(target.project, "/project")
            XCTAssertThrowsError(try ContextTarget.locate(focusedTitle: "未知页面", sessionRoots: [directory.path], databasePath: path))
        }
    }

    func testInvalidThreadIdentifierIsRejected() throws {
        try database("INSERT INTO threads VALUES('not-a-thread','任务',NULL,0);") { path in
            XCTAssertThrowsError(try FocusedContextTarget.threadID(title: "任务", databasePath: path))
        }
    }

    func testFocusFingerprintRejectsWindowProcessOrTitleChanges() {
        let window = AXUIElementCreateApplication(100)
        let focused = FocusedContextTarget.Focus(processID: 100, window: window, title: "任务")
        XCTAssertEqual(focused, FocusedContextTarget.Focus(processID: 100, window: window, title: "任务"))
        XCTAssertNotEqual(focused, FocusedContextTarget.Focus(processID: 101, window: window, title: "任务"))
        XCTAssertNotEqual(focused, FocusedContextTarget.Focus(processID: 100, window: window, title: "另一个任务"))
        XCTAssertNotEqual(focused, FocusedContextTarget.Focus(processID: 100, window: AXUIElementCreateApplication(200), title: "任务"))
    }
}
