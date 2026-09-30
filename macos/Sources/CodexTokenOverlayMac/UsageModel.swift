import AppKit
import SwiftUI
import CodexTokenCore

@MainActor
final class UsageModel: ObservableObject {
    @Published var cost: CodexCostReport?
    @Published var quota: CodexQuotaReport?
    @Published var costBusy = false
    @Published var quotaBusy = false
    @Published var costError: String?
    @Published var quotaError: String?
    @Published var automaticQuota: Bool {
        didSet { UserDefaults.standard.set(automaticQuota, forKey: "contextUsage.automaticQuota") }
    }
    private var timer: Timer?
    private var lastQuotaRead = Date.distantPast

    init() { automaticQuota = UserDefaults.standard.bool(forKey: "contextUsage.automaticQuota") }

    var today: CodexCostReport.Day? {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return cost?.daily?.first { $0.date == format.string(from: Date()) }
    }

    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.openai.codex" }) else { return }
                self.refreshCost()
                if self.automaticQuota && Date().timeIntervalSince(self.lastQuotaRead) >= 300 { self.refreshQuota() }
            }
        }
        refreshCost()
        if automaticQuota { refreshQuota() }
    }

    func refreshCost() {
        guard !costBusy else { return }
        costBusy = true
        Task {
            do {
                cost = try await Task.detached(priority: .utility) { try UsageBackend.cost() }.value
                costError = nil
            } catch { costError = error.localizedDescription }
            costBusy = false
        }
    }

    func refreshQuota() {
        guard !quotaBusy else { return }
        quotaBusy = true
        lastQuotaRead = Date()
        Task {
            do {
                quota = try await Task.detached(priority: .utility) { try UsageBackend.quota() }.value
                quotaError = nil
            } catch { quotaError = error.localizedDescription }
            quotaBusy = false
        }
    }
}
