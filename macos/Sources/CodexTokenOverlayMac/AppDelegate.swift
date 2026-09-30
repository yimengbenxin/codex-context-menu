import AppKit
import Foundation
import CodexTokenCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let visibleFieldsKey = "visibleFields"
    private static let repositoryURL = URL(string: "https://github.com/yimengbenxin/codex-context-menu")!

    private let routeMonitor = CodexIPCActiveThreadMonitor()
    private let routePreferenceTracker = ActiveThreadPreferenceTracker()
    private let logMonitor = TokenLogMonitor()
    private let pollQueue = DispatchQueue(
        label: "io.github.soleillevant0125.CodexTokenOverlay.logs",
        qos: .utility
    )

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var summaryMenuItem: NSMenuItem!
    private var taskMenuItem: NSMenuItem!
    private var routeMenuItem: NSMenuItem!
    private var lockMenuItem: NSMenuItem!
    private var loginMenuItem: NSMenuItem!
    private var fieldMenuItems: [DisplayField: NSMenuItem] = [:]

    private var visibleFields: DisplayField = .defaultFields
    private var lastSnapshot: TokenSnapshot?
    private var lastRouteStatus = ActiveThreadRouteStatus(
        threadID: nil,
        activeWindowCount: 0,
        isConnected: false,
        version: 0,
        socketPath: nil,
        lastError: nil
    )
    private var pollInFlight = false
    private var isTaskLocked = false
    private var forceNextPoll = true
    private let contextSettings = ContextSettingsController()
    private var contextMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.mainMenu = NativeEditingMenu.make()
        let backend = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexContextTool/backend")
        if FileManager.default.isExecutableFile(atPath: backend.path) {
            let process = Process()
            process.executableURL = backend
            process.arguments = ["--restore-integration"]
            try? process.run()
        }
        let savedFields = UserDefaults.standard.integer(forKey: Self.visibleFieldsKey)
        let restoredFields = DisplayField(rawValue: savedFields).intersection(.allFields)
        if !restoredFields.isEmpty {
            visibleFields = restoredFields
        }

        configureStatusItem()
        configureMenu()
        refreshFieldMenuStates()
        refreshLoginItemState()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.08
        refresh()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(codexLifecycleChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(codexLifecycleChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        updateCodexVisibility()
        contextSettings.identifyCurrent = { [weak self] in self?.identifyContextTarget() }
        contextSettings.usage.startMonitoring()
        if CommandLine.arguments.contains("--show-settings") {
            contextSettings.chooseProject()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        routeMonitor.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        contextSettings.chooseProject()
        return false
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshFieldMenuStates()
        refreshLoginItemState()
        updateMenu(snapshot: lastSnapshot, routeStatus: lastRouteStatus)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "Codex —"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.toolTip = L10n.waiting
        }
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        summaryMenuItem = NSMenuItem(title: L10n.noTokenSnapshot, action: nil, keyEquivalent: "")
        summaryMenuItem.isEnabled = false
        menu.addItem(summaryMenuItem)

        taskMenuItem = NSMenuItem(title: "\(L10n.currentTask)：—", action: nil, keyEquivalent: "")
        taskMenuItem.isEnabled = false
        menu.addItem(taskMenuItem)

        routeMenuItem = NSMenuItem(title: L10n.ipcFallback, action: nil, keyEquivalent: "")
        routeMenuItem.isEnabled = false
        menu.addItem(routeMenuItem)
        menu.addItem(.separator())

        contextMenuItem = NSMenuItem(title: "更改当前对话所在项目的上下文…", action: #selector(changeProjectContext(_:)), keyEquivalent: "")
        contextMenuItem.target = self
        menu.addItem(contextMenuItem)
        let chooseProject = NSMenuItem(title: "手动选择项目并更改上下文…", action: #selector(chooseContextProject(_:)), keyEquivalent: "")
        chooseProject.target = self
        menu.addItem(chooseProject)
        menu.addItem(.separator())

        let fieldsItem = NSMenuItem(title: L10n.displayFields, action: nil, keyEquivalent: "")
        let fieldsMenu = NSMenu()
        for field in DisplayField.ordered {
            let item = NSMenuItem(
                title: L10n.fieldName(field),
                action: #selector(toggleField(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = field.rawValue
            fieldsMenu.addItem(item)
            fieldMenuItems[field] = item
        }
        fieldsItem.submenu = fieldsMenu
        menu.addItem(fieldsItem)

        lockMenuItem = NSMenuItem(
            title: L10n.lockTask,
            action: #selector(toggleTaskLock(_:)),
            keyEquivalent: ""
        )
        lockMenuItem.target = self
        menu.addItem(lockMenuItem)

        loginMenuItem = NSMenuItem(
            title: "随登录启动（本机启动项）",
            action: nil,
            keyEquivalent: ""
        )
        loginMenuItem.isEnabled = false
        menu.addItem(loginMenuItem)
        menu.addItem(.separator())

        let openSessionsItem = NSMenuItem(
            title: L10n.openSessions,
            action: #selector(openSessionsDirectory(_:)),
            keyEquivalent: ""
        )
        openSessionsItem.target = self
        menu.addItem(openSessionsItem)

        let openProjectItem = NSMenuItem(
            title: L10n.openProject,
            action: #selector(openProjectPage(_:)),
            keyEquivalent: ""
        )
        openProjectItem.target = self
        menu.addItem(openProjectItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.quit,
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func refresh() {
        guard statusItem.isVisible, !pollInFlight else {
            return
        }

        let routeStatus = routeMonitor.status()
        let preferredThreadID = routePreferenceTracker.preferredThreadID(for: routeStatus)
        let routeChanged = routeStatus.version != lastRouteStatus.version
        let forceFullScan = forceNextPoll || routeChanged
        let locked = isTaskLocked

        forceNextPoll = false
        lastRouteStatus = routeStatus
        pollInFlight = true
        nonisolated(unsafe) let monitor = logMonitor

        pollQueue.async { [weak self] in
            guard let self else {
                return
            }

            monitor.pinActiveSession = locked
            monitor.preferredThreadID = locked ? nil : preferredThreadID
            let snapshot = monitor.poll(forceFullScan: forceFullScan)

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.pollInFlight = false
                self.apply(snapshot: snapshot, routeStatus: routeStatus)
            }
        }
    }

    private func apply(snapshot: TokenSnapshot?, routeStatus: ActiveThreadRouteStatus) {
        lastSnapshot = snapshot
        if let snapshot, contextSettings.model.threadID == snapshot.threadID {
            contextSettings.model.observedWindow = snapshot.contextWindowTokens
            contextSettings.model.observedTarget = snapshot.targetContextBudgetTokens
        }

        if let snapshot {
            let title = TokenFormatter.statusTitle(snapshot: snapshot, fields: visibleFields)
            statusItem.button?.title = title.isEmpty ? "Codex —" : "Codex \(title)"
            statusItem.button?.toolTip = TokenFormatter.fullSummary(snapshot: snapshot)
        } else {
            statusItem.button?.title = routeStatus.threadID == nil ? "Codex —" : "Codex …"
            statusItem.button?.toolTip = L10n.noTokenSnapshot
        }

        updateMenu(snapshot: snapshot, routeStatus: routeStatus)
    }

    private func updateMenu(snapshot: TokenSnapshot?, routeStatus: ActiveThreadRouteStatus) {
        if let snapshot {
            summaryMenuItem.title = TokenFormatter.fullSummary(snapshot: snapshot)
            if let target = snapshot.targetContextBudgetTokens {
                summaryMenuItem.title += " · 自适应预算 \(target / 1000)K（软阈值，非模型上限）"
            }
            taskMenuItem.title = "\(L10n.currentTask)：\(TokenFormatter.shortThreadID(snapshot.threadID))"
        } else {
            summaryMenuItem.title = L10n.noTokenSnapshot
            let routeThread = routeStatus.threadID.map(TokenFormatter.shortThreadID) ?? "—"
            taskMenuItem.title = "\(L10n.currentTask)：\(routeThread)"
        }

        routeMenuItem.title = routeStatus.isConnected ? L10n.ipcConnected : L10n.ipcFallback
        lockMenuItem.title = isTaskLocked ? L10n.lockedTask : L10n.lockTask
        lockMenuItem.state = isTaskLocked ? .on : .off
        lockMenuItem.isEnabled = snapshot != nil || isTaskLocked
        contextMenuItem.isEnabled = routeStatus.isConnected && routeStatus.activeWindowCount == 1 && routeStatus.threadID != nil
    }

    private func refreshFieldMenuStates() {
        for (field, item) in fieldMenuItems {
            item.state = visibleFields.contains(field) ? .on : .off
        }
    }

    private func refreshLoginItemState() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.wen.CodexContextMenu.plist").path
        loginMenuItem.state = FileManager.default.fileExists(atPath: path) ? .on : .off
    }

    @objc private func toggleField(_ sender: NSMenuItem) {
        let field = DisplayField(rawValue: sender.tag)
        var nextFields = visibleFields
        if nextFields.contains(field) {
            nextFields.remove(field)
        } else {
            nextFields.insert(field)
        }

        guard !nextFields.isEmpty else {
            NSSound.beep()
            return
        }

        visibleFields = nextFields
        UserDefaults.standard.set(visibleFields.rawValue, forKey: Self.visibleFieldsKey)
        refreshFieldMenuStates()

        if let lastSnapshot {
            apply(snapshot: lastSnapshot, routeStatus: lastRouteStatus)
        }
    }

    @objc private func toggleTaskLock(_ sender: NSMenuItem) {
        isTaskLocked.toggle()
        forceNextPoll = true
        updateMenu(snapshot: lastSnapshot, routeStatus: lastRouteStatus)
        refresh()
    }

    @objc private func openSessionsDirectory(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: logMonitor.sessionRoot, isDirectory: true))
    }

    @objc private func openProjectPage(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(Self.repositoryURL)
    }

    @objc private func quitApplication(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    @objc private func codexLifecycleChanged(_ notification: Notification) {
        updateCodexVisibility()
    }

    private func updateCodexVisibility() {
        statusItem.isVisible = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.openai.codex" }
    }

    @objc private func chooseContextProject(_ sender: NSMenuItem) {
        contextSettings.chooseProject()
    }

    @objc private func changeProjectContext(_ sender: NSMenuItem) {
        contextSettings.chooseProject()
        identifyContextTarget()
    }

    private func identifyContextTarget() {
        let route = routeMonitor.status()
        guard route.isConnected, route.activeWindowCount == 1, let threadID = route.threadID else {
            contextSettings.model.failTarget(route.activeWindowCount > 1
                ? "检测到多个 Codex 窗口，无法确定焦点。请粘贴目标对话的深度链接定位。"
                : "尚未取得唯一的桌面对话订阅，请稍后重试或粘贴深度链接。")
            return
        }
        contextSettings.model.identifying = true
        contextSettings.model.error = nil
        Task {
            do {
                let target = try await Task.detached(priority: .userInitiated) {
                    try ContextTarget.locate(link: "codex://threads/\(threadID)", requireDesktopRoot: true)
                }.value
                let current = routeMonitor.status()
                guard current.isConnected, current.activeWindowCount == 1, current.threadID == threadID else {
                    contextSettings.model.failTarget("定位期间对话订阅发生变化，未锁定新目标。请再次识别或使用链接。")
                    contextSettings.model.identifying = false
                    return
                }
                let snapshot = lastSnapshot?.threadID == threadID ? lastSnapshot : nil
                contextSettings.present(project: target.project, threadID: threadID,
                    observedWindow: snapshot?.contextWindowTokens, observedTarget: snapshot?.targetContextBudgetTokens, origin: .automatic)
            } catch { contextSettings.model.failTarget(error.localizedDescription) }
            contextSettings.model.identifying = false
        }
    }
}
