import Foundation

public struct CodexCostReport: Decodable, Sendable {
    public struct Totals: Decodable, Sendable {
        public let inputTokens: Int64?
        public let outputTokens: Int64?
        public let cacheReadTokens: Int64?
        public let cacheCreationTokens: Int64?
        public let reasoningTokens: Int64?
        public let totalTokens: Int64?
        public let totalCost: Double?
        public let provenance: String?
        public let coverage: Coverage?
        public let incompleteRequestCount: Int?
    }
    public struct Day: Decodable, Identifiable, Sendable {
        public let date: String
        public let inputTokens: Int64?
        public let outputTokens: Int64?
        public let cacheReadTokens: Int64?
        public let cacheCreationTokens: Int64?
        public let reasoningTokens: Int64?
        public let totalTokens: Int64?
        public let totalCost: Double?
        public let modelsUsed: [String]?
        public let modelBreakdowns: [ModelBreakdown]?
        public let incompleteRequestCount: Int?
        public var id: String { date }
    }
    public struct Coverage: Decodable, Sendable {
        public let priced: Int?
        public let unpriced: Int?
        public let unmetered: Int?
        public let estimated: Int?
    }
    public struct ModelBreakdown: Decodable, Sendable {
        public let modelName: String
        public let totalTokens: Int64?
        public let cost: Double?
        public let incompleteRequestCount: Int?
    }
    public struct Project: Decodable, Sendable {
        public let name: String
        public let path: String?
        public let totalTokens: Int64?
        public let totalCost: Double?
        public let daily: [Day]?
        public let modelBreakdowns: [ModelBreakdown]?
        public let sources: [Source]?
    }
    public struct Source: Decodable, Sendable {
        public let name: String
        public let path: String?
        public let totalTokens: Int64?
        public let totalCost: Double?
        public let daily: [Day]?
        public let modelBreakdowns: [ModelBreakdown]?
    }
    public let provider: String
    public let source: String?
    public let updatedAt: String?
    public let currencyCode: String?
    public let sessionTokens: Int64?
    public let sessionCostUSD: Double?
    public let historyDays: Int?
    public let reportingPeriod: String?
    public let historyLabel: String?
    public let historyCoverageIsEstablished: Bool?
    public let daily: [Day]?
    public let totals: Totals?
    public let last30DaysTokens: Int64?
    public let last30DaysCostUSD: Double?
    public let meteredCostUSD: Double?
    public let provenance: String?
    public let coverage: Coverage?
    public let incompleteRequestCount: Int?
    public let projects: [Project]?
    public let error: CodexUsageFailure?
}

public struct CodexUsageFailure: Decodable, Sendable {
    public let message: String
    public let code: Int32?
    public let kind: String?
}

public struct CodexQuotaReport: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public let usedPercent: Double?
        public let windowMinutes: Int?
        public let resetsAt: String?
        public let resetDescription: String?
        public let nextRegenPercent: Double?
        public let isSyntheticPlaceholder: Bool?
        public var remainingPercent: Double? {
            guard isSyntheticPlaceholder != true, let usedPercent, usedPercent.isFinite, usedPercent >= 0 else { return nil }
            return min(100, max(0, 100 - usedPercent))
        }
    }
    public struct NamedWindow: Decodable, Sendable {
        public let id: String
        public let title: String
        public let window: Window
        public let usageKnown: Bool?
    }
    public struct Usage: Decodable, Sendable {
        public let primary: Window?
        public let secondary: Window?
        public let tertiary: Window?
        public let updatedAt: String?
        public let loginMethod: String?
        public let accountEmail: String?
        public let accountOrganization: String?
        public let identity: Identity?
        public let extraRateWindows: [NamedWindow]?
        public let providerCost: ProviderCost?
        public var redactedAccount: String? {
            guard let email = identity?.accountEmail ?? accountEmail,
                  let separator = email.firstIndex(of: "@"), separator != email.startIndex else { return nil }
            return "\(email.prefix(1))•••\(email[separator...])"
        }
    }
    public struct Identity: Decodable, Sendable {
        public let providerID: String?
        public let accountEmail: String?
        public let accountOrganization: String?
        public let loginMethod: String?
    }
    public struct ProviderCost: Decodable, Sendable {
        public let used: Double?
        public let limit: Double?
        public let currencyCode: String?
        public let period: String?
        public let resetsAt: String?
        public let nextRegenAmount: Double?
        public let personalUsed: Double?
        public let balance: Double?
        public let balanceUpdatedAt: String?
        public let balanceIsWorkspace: Bool?
        public let updatedAt: String?
        public let balanceIsUnavailable: Bool?
    }
    public struct RateWindowLabels: Decodable, Sendable {
        public let primary: String?
        public let secondary: String?
        public let tertiary: String?
    }
    public struct Pace: Decodable, Sendable {
        public let primary: PaceWindow?
        public let secondary: PaceWindow?
        public let tertiary: PaceWindow?
    }
    public struct PaceWindow: Decodable, Sendable {
        public let stage: String?
        public let deltaPercent: Double?
        public let expectedUsedPercent: Double?
        public let willLastToReset: Bool?
        public let etaSeconds: Double?
        public let runOutProbability: Double?
        public let summary: String?
    }
    public struct Status: Decodable, Sendable {
        public let indicator: String?
        public let description: String?
        public let updatedAt: String?
        public let url: String?
    }
    public struct Credits: Decodable, Sendable {
        public let remaining: Double?
        public let events: [CreditEvent]?
        public let updatedAt: String?
        public let codexCreditLimit: CreditLimit?
        public let balanceReadSucceeded: Bool?
        public let creditsAvailable: Bool?
        public let balanceIsWorkspace: Bool?
    }
    public struct CreditEvent: Decodable, Sendable {
        public let id: String?
        public let date: String?
        public let service: String?
        public let creditsUsed: Double?
    }
    public struct CreditLimit: Decodable, Sendable {
        public let title: String?
        public let used: Double?
        public let limit: Double?
        public let remaining: Double?
        public let remainingPercent: Double?
        public let resetsAt: String?
        public let updatedAt: String?
    }
    public let provider: String
    public let source: String?
    public let usage: Usage?
    public let account: String?
    public let version: String?
    public let status: Status?
    public let rateWindowLabels: RateWindowLabels?
    public let credits: Credits?
    public let diagnostic: String?
    public let pace: Pace?
    public let error: CodexUsageFailure?
}
