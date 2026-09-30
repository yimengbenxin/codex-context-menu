import Foundation

public struct CodexCostReport: Decodable, Sendable {
    public struct Totals: Decodable, Sendable {
        public let inputTokens: Int64?
        public let outputTokens: Int64?
        public let cacheReadTokens: Int64?
        public let totalTokens: Int64?
    }
    public struct Day: Decodable, Identifiable, Sendable {
        public let date: String
        public let inputTokens: Int64?
        public let outputTokens: Int64?
        public let cacheReadTokens: Int64?
        public let totalTokens: Int64?
        public var id: String { date }
    }
    public let provider: String
    public let source: String?
    public let updatedAt: String?
    public let historyCoverageIsEstablished: Bool?
    public let daily: [Day]?
    public let totals: Totals?
    public let error: CodexUsageFailure?
}

public struct CodexUsageFailure: Decodable, Sendable {
    public let message: String
}

public struct CodexQuotaReport: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public let usedPercent: Double?
        public let windowMinutes: Int?
        public let resetsAt: String?
        public var remainingPercent: Double? {
            guard let usedPercent, usedPercent.isFinite else { return nil }
            return min(100, max(0, 100 - usedPercent))
        }
    }
    public struct Usage: Decodable, Sendable {
        public let primary: Window?
        public let secondary: Window?
        public let tertiary: Window?
        public let updatedAt: String?
        public let loginMethod: String?
        public let accountEmail: String?
        public var redactedAccount: String? {
            guard let accountEmail, let separator = accountEmail.firstIndex(of: "@") else { return nil }
            return "\(accountEmail.prefix(1))•••\(accountEmail[separator...])"
        }
    }
    public let provider: String
    public let source: String?
    public let usage: Usage?
    public let error: CodexUsageFailure?
}
