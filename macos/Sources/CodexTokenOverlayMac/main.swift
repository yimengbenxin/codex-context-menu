import AppKit
import CodexTokenCore

if CommandLine.arguments.contains("--diagnose") {
    let monitor = CodexIPCActiveThreadMonitor()
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    let route = monitor.status()
    let logs = TokenLogMonitor()
    logs.preferredThreadID = route.activeWindowCount == 1 ? route.threadID : nil
    let snapshot = logs.poll(forceFullScan: true)
    let matched = route.isConnected && route.activeWindowCount == 1 && snapshot?.threadID == route.threadID
    var result: [String: Any] = ["connected": route.isConnected, "activeWindows": route.activeWindowCount,
                               "verifiedCurrentThread": matched, "thread": route.threadID ?? ""]
    if matched, let snapshot {
        result["project"] = try? ContextTarget.project(logPath: snapshot.logPath, threadID: snapshot.threadID)
        result["runtimeWindow"] = snapshot.contextWindowTokens
        result["adaptiveTarget"] = snapshot.targetContextBudgetTokens
    }
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    monitor.stop()
    exit(0)
}

let application = NSApplication.shared
let applicationDelegate = MainActor.assumeIsolated { AppDelegate() }

application.setActivationPolicy(.accessory)
application.delegate = applicationDelegate
application.run()
