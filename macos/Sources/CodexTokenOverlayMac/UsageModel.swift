import AppKit
import SwiftUI
import CodexTokenCore

enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case week = "近 7 天", month = "近 30 天", monthToDate = "本月", all = "全部历史"
    var id: String { rawValue }
    var arguments: [String] {
        switch self {
        case .week: return ["--days", "7"]
        case .month: return ["--days", "30"]
        case .monthToDate: return ["--period", "month-to-date"]
        case .all: return ["--period", "all"]
        }
    }
}

@MainActor
final class UsageModel: ObservableObject {
    @Published var cost: CodexCostReport?
    @Published var quota: CodexQuotaReport?
    @Published var costBusy = false
    @Published var quotaBusy = false
    @Published var costError: String?
    @Published var quotaError: String?
    @Published var currentSession: TokenSnapshot?
    @Published var costPeriod: UsagePeriod?
    @Published var period: UsagePeriod = .month {
        didSet { if period != oldValue { refreshCost() } }
    }
    @Published var automaticQuota: Bool {
        didSet { UserDefaults.standard.set(automaticQuota, forKey: "contextUsage.automaticQuota") }
    }
    private var timer: Timer?
    private var lastQuotaRead = Date.distantPast
    private let costReader: @Sendable (UsagePeriod, Bool) throws -> CodexCostReport

    init(costReader: @escaping @Sendable (UsagePeriod, Bool) throws -> CodexCostReport = { try UsageBackend.cost(period: $0, refresh: $1) }) {
        self.costReader = costReader
        automaticQuota = UserDefaults.standard.bool(forKey: "contextUsage.automaticQuota")
    }

    var today: CodexCostReport.Day? {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return cost?.daily?.first { $0.date == format.string(from: Date()) }
    }

    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshCost()
                if self.automaticQuota && Date().timeIntervalSince(self.lastQuotaRead) >= 300 { self.refreshQuota() }
            }
        }
        refreshCost()
        if automaticQuota { refreshQuota() }
    }

    func refreshCost(refresh: Bool = false) {
        guard !costBusy else { return }
        costBusy = true
        let requestedPeriod = period
        let reader = costReader
        Task {
            do {
                let report = try await Task.detached(priority: .utility) { try reader(requestedPeriod, refresh) }.value
                if requestedPeriod == period {
                    cost = report
                    costPeriod = requestedPeriod
                    costError = nil
                }
            } catch { if requestedPeriod == period { costError = error.localizedDescription } }
            costBusy = false
            if requestedPeriod != period { refreshCost() }
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
