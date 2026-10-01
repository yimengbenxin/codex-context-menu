import XCTest
import AppKit
@testable import CodexTokenOverlayMac

final class ContextFormTests: XCTestCase {
    @MainActor
    func testCompactionWarningAndModelSafetyLimit() throws {
        let raw = Data("""
        {"root":"/project","path":"/settings","revision":"r","adaptive":false,"adaptive_available":true,"trusted":true,"inherited":[],
        "adaptive_preview":{"model":"fixture","tiers":[272000,572000,872000],"maximum":872000,"percent":95}}
        """.utf8)
        let model = ContextSettingsModel()
        model.status = try JSONDecoder().decode(ProjectContextStatus.self, from: raw)
        model.mode = .custom
        model.input = "272"
        model.compactionInput = "90"
        XCTAssertFalse(model.compactionWarning)
        model.compactionInput = "91"
        XCTAssertTrue(model.compactionWarning)
        XCTAssertNil(model.compactionValidation)
        model.compactionInput = "99"
        XCTAssertNil(model.compactionValidation)
        model.compactionInput = "100"
        XCTAssertNotNil(model.compactionValidation)
        let limited = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\"percent\":95", with: "\"percent\":95,\"compaction\":{\"budget\":870000,\"maximum_percent\":90}")
        model.status = try JSONDecoder().decode(ProjectContextStatus.self, from: Data(limited.utf8))
        model.mode = .default
        model.compactionInput = "95"
        XCTAssertNotNil(model.compactionValidation)
        model.compactionInput = "90"
        XCTAssertNil(model.compactionValidation)
        model.compactionInput = ""
        XCTAssertFalse(model.compactionWarning)
        XCTAssertNil(model.compactionValidation)
    }
    private let defaults = AdaptiveOptions(lower_percent: 35, upper_percent: 55)
    func testAdaptiveInputsValidateThresholdsAndOrderedOptionalTiers() throws {
        let selected = try AdaptiveOptions.parse(lower: "30", upper: "50", tiers: ["272", "485", "872"], defaults: defaults)
        XCTAssertEqual(selected.lower_percent, 30)
        XCTAssertEqual(selected.tiers, [272000, 485000, 872000])
        XCTAssertEqual(try AdaptiveOptions.parse(lower: "", upper: " ", tiers: ["", "", ""], defaults: defaults), defaults)
        XCTAssertThrowsError(try AdaptiveOptions.parse(lower: "60", upper: "50", tiers: ["", "", ""], defaults: defaults))
        XCTAssertThrowsError(try AdaptiveOptions.parse(lower: "nan", upper: "65", tiers: ["", "", ""], defaults: defaults))
        XCTAssertThrowsError(try AdaptiveOptions.parse(lower: "45", upper: "65", tiers: ["485", "272", "872"], defaults: defaults))
    }

    func testBlankThresholdsUseProducerDefaultsAndKeepExplicitOverrides() throws {
        XCTAssertEqual(try AdaptiveOptions.parse(lower: "", upper: "65", tiers: ["", "", ""], defaults: defaults).lower_percent, 35)
        XCTAssertEqual(try AdaptiveOptions.parse(lower: "45", upper: "", tiers: ["", "", ""], defaults: defaults).upper_percent, 55)
        XCTAssertThrowsError(try AdaptiveOptions.parse(lower: "60", upper: "", tiers: ["", "", ""], defaults: defaults))
        let changed = AdaptiveOptions(lower_percent: 20, upper_percent: 40)
        XCTAssertEqual(try AdaptiveOptions.parse(lower: "", upper: "", tiers: ["", "", ""], defaults: changed), changed)
    }

    func testStatusClickDispatchPreservesRightClickAndDoubleClick() {
        XCTAssertEqual(StatusItemGesture.action(rightClick: true, clickCount: 2), .menu)
        XCTAssertEqual(StatusItemGesture.action(rightClick: false, clickCount: 1), .delayedMenu)
        XCTAssertEqual(StatusItemGesture.action(rightClick: false, clickCount: 2), .window)
    }

    @MainActor
    func testQuickFormDoesNotReplaceUnsavedMainWindowDraftAndDisplaysNumericDefaults() throws {
        let main = ContextSettingsController()
        main.model.mode = .custom
        main.model.input = "485"
        let quick = QuickContextController()
        let document = """
        {"root":"/project","path":"/settings","revision":"r","adaptive":false,"adaptive_available":true,"trusted":true,"inherited":[],
         "adaptive_defaults":{"lower_percent":35,"upper_percent":55,"tiers":[null,null,null]},
         "adaptive_preview":{"model":"fixture","tiers":[300000,600000,900000],"maximum":900000}}
        """
        quick.model.status = try JSONDecoder().decode(ProjectContextStatus.self, from: Data(document.utf8))
        quick.model.mode = .adaptive
        XCTAssertEqual(quick.model.thresholdPlaceholder(true), "35")
        XCTAssertEqual(quick.model.thresholdPlaceholder(false), "55")
        XCTAssertEqual((0..<3).map { quick.model.tierPlaceholder($0) }, ["300", "600", "900"])
        XCTAssertEqual(try quick.model.adaptiveOptions(), defaults)
        XCTAssertEqual(main.model.input, "485")
        XCTAssertEqual(main.model.mode, .custom)
    }

    @MainActor
    func testAdaptiveEditsBecomeDirtyAndRepairBlocksSaving() {
        let model = ContextSettingsModel()
        model.mode = .adaptive
        model.lowerThreshold = "30"
        XCTAssertTrue(model.dirty)
        model.upperThreshold = "20"
        XCTAssertNotNil(model.validation)
        model.repairingRuntime = true
        XCTAssertFalse(model.canSave)
    }
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

    @MainActor
    func testStatisticsPreserveUnknownValuesAndSettingsDraft() async throws {
        let data = Data("""
        {"model":"fixture","budget":272000,"groups":[{"percent":95,"samples":12,"automatic":10,
        "manual":1,"failed":1,"measured":10,"unknown":0,"crossed":3,"observed_rate":0.3,
        "mean_excess":5000,"p95_excess":5000,"recommended_percent":93}],
        "recent":[{"at":1000,"percent":null,"before_input":null,"before_total":null,"after_total":90000,
        "duration_ms":1000,"status":"completed","manual":false}]}
        """.utf8)
        let model = ContextSettingsModel()
        model.mode = .custom
        model.input = "485"
        model.compactionInput = "99"
        model.compactionStatistics = try JSONDecoder().decode(CompactionStatistics.self, from: data)
        XCTAssertEqual(model.compactionStatistics?.groups.first?.recommended_percent, 93)
        XCTAssertNil(model.compactionStatistics?.recent.first?.before_total)
        XCTAssertEqual(model.input, "485")
        XCTAssertEqual(model.compactionInput, "99")
        XCTAssertEqual(model.mode, .custom)
    }

    @MainActor
    func testStatisticsRefreshPreservesDraftOnSuccessAndFailure() async throws {
        let data = Data("""
        {"root":"/project","path":"/project/.codex/config.toml","revision":"first",
        "adaptive":false,"adaptive_available":true,"trusted":true,"inherited":[],
        "compaction_statistics":{"model":"fixture","budget":272000,"groups":[],"recent":[]}}
        """.utf8)
        let result = try JSONDecoder().decode(ProjectContextStatus.self, from: data)
        let model = ContextSettingsModel()
        model.project = "/project"
        model.status = result
        model.mode = .custom
        model.input = "485"
        model.compactionInput = "99"
        await model.refreshStatistics(reader: { arguments in
            XCTAssertEqual(arguments, ["status", "/project"])
            return result
        })?.value
        XCTAssertEqual(model.compactionStatistics?.budget, 272000)
        XCTAssertNil(model.statisticsError)
        await model.refreshStatistics(reader: { _ in
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "read failed"])
        })?.value
        XCTAssertEqual(model.compactionStatistics?.budget, 272000)
        XCTAssertTrue(model.statisticsError?.contains("read failed") == true)
        XCTAssertFalse(model.statisticsBusy)
        XCTAssertEqual(model.mode, .custom)
        XCTAssertEqual(model.input, "485")
        XCTAssertEqual(model.compactionInput, "99")
    }

    @MainActor
    func testStatisticsRefreshDiscardsOldTargetResponse() async throws {
        let data = Data("""
        {"root":"/project","path":"/project/.codex/config.toml","revision":"first",
        "adaptive":false,"adaptive_available":true,"trusted":true,"inherited":[],
        "compaction_statistics":{"model":"fixture","budget":272000,"groups":[],"recent":[]}}
        """.utf8)
        let result = try JSONDecoder().decode(ProjectContextStatus.self, from: data)
        let model = ContextSettingsModel()
        model.project = "/project"
        model.status = result
        let refresh = model.refreshStatistics(reader: { _ in result })
        model.status = nil
        await refresh?.value
        XCTAssertNil(model.compactionStatistics)
        XCTAssertFalse(model.statisticsBusy)
    }
}
