import AppKit
import ApplicationServices
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
    private var statusMenu: NSMenu!
    private var pendingStatusClick: DispatchWorkItem?
    private var compactMenuItem: NSMenuItem!
    private var iconOnly = UserDefaults.standard.object(forKey: "menu.iconOnly") as? Bool ?? true
    private let quickContext = QuickContextController()

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
        quickContext.openSettings = { [weak self] in self?.contextSettings.chooseProject() }
        contextSettings.usage.startMonitoring()
        contextSettings.model.inspectRuntime()
        if !CommandLine.arguments.contains("--background") || !FileManager.default.isExecutableFile(atPath: backend.path) {
            contextSettings.chooseProject()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingStatusClick?.cancel()
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
            button.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Codex 上下文快捷设置")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.toolTip = L10n.waiting
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

        let quickItem = NSMenuItem(title: "修改当前对话上下文", action: nil, keyEquivalent: "")
        quickItem.submenu = makeQuickMenu()
        menu.addItem(quickItem)
        let applicationQuick = NSMenuItem(title: "上下文", action: nil, keyEquivalent: "")
        applicationQuick.submenu = makeQuickMenu()
        NSApp.mainMenu?.addItem(applicationQuick)

        contextMenuItem = NSMenuItem(title: "识别当前对话并更改上下文…", action: #selector(changeProjectContext(_:)), keyEquivalent: "")
        contextMenuItem.target = self
        menu.addItem(contextMenuItem)
        let chooseProject = NSMenuItem(title: "手动选择项目并更改上下文…", action: #selector(chooseContextProject(_:)), keyEquivalent: "")
        chooseProject.target = self
        menu.addItem(chooseProject)
        menu.addItem(.separator())

        compactMenuItem = NSMenuItem(title: "菜单栏仅显示图标", action: #selector(toggleCompactMenu(_:)), keyEquivalent: "")
        compactMenuItem.target = self
        menu.addItem(compactMenuItem)

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

        statusMenu = menu
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        pendingStatusClick?.cancel()
        let gesture = StatusItemGesture.action(rightClick: NSApp.currentEvent?.type == .rightMouseUp,
            clickCount: NSApp.currentEvent?.clickCount ?? 1)
        if gesture == .window {
            quickContext.close()
            contextSettings.chooseProject()
        } else if gesture == .menu {
            showStatusMenu()
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.showStatusMenu()
            }
            pendingStatusClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.04, execute: work)
        }
    }

    private func showStatusMenu() {
        guard let button = statusItem.button else { return }
        statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
    }

    private func makeQuickMenu() -> NSMenu {
        let menu = NSMenu(title: "上下文")
        for (index, mode) in ContextMode.allCases.enumerated() {
            let item = NSMenuItem(title: mode.title + "…", action: #selector(quickContextMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleCompactMenu(_ sender: NSMenuItem) {
        iconOnly.toggle()
        UserDefaults.standard.set(iconOnly, forKey: "menu.iconOnly")
        apply(snapshot: lastSnapshot, routeStatus: lastRouteStatus)
    }

    @objc private func quickContextMode(_ sender: NSMenuItem) {
        guard ContextMode.allCases.indices.contains(sender.tag), let button = statusItem.button else { return }
        quickContext.present(relativeTo: button, mode: ContextMode.allCases[sender.tag])
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

        if iconOnly { statusItem.button?.title = "" }
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
        contextMenuItem.isEnabled = routeStatus.isConnected || AXIsProcessTrusted()
        compactMenuItem.state = iconOnly ? .on : .off
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
        contextSettings.model.identifying = true
        contextSettings.model.error = nil
        contextSettings.model.focusPermissionRequired = false
        Task {
            defer { contextSettings.model.identifying = false }
            do {
                let (target, title) = try await FocusedContextTarget.resolve(requestPermission: true)
                let snapshot = lastSnapshot?.threadID == target.threadID ? lastSnapshot : nil
                contextSettings.present(project: target.project, threadID: target.threadID,
                    observedWindow: snapshot?.contextWindowTokens, observedTarget: snapshot?.targetContextBudgetTokens,
                    origin: .focused, title: title)
            } catch {
                contextSettings.model.focusPermissionRequired = !AXIsProcessTrusted()
                contextSettings.model.failTarget(error.localizedDescription)
            }
        }
    }
}
