import XCTest
@testable import CodexTokenCore

final class UsageReportTests: XCTestCase {
    func testMissingQuotaIsNotReportedAsZeroAndIdentityIsRedacted() throws {
        let raw = Data("""
        {"provider":"codex","source":"oauth","usage":{"primary":null,
        "secondary":{"usedPercent":6,"windowMinutes":10080,"resetsAt":"2026-10-07T00:00:00Z"},
        "accountEmail":"someone@example.com","updatedAt":"2026-09-30T00:00:00Z"}}
        """.utf8)
        let report = try JSONDecoder().decode(CodexQuotaReport.self, from: raw)
        XCTAssertNil(report.usage?.primary)
        XCTAssertEqual(report.usage?.secondary?.remainingPercent, 94)
        XCTAssertEqual(report.usage?.redactedAccount, "s•••@example.com")
    }

    func testPartialHistoryAndCachedTokensStaySeparate() throws {
        let raw = Data("""
        {"provider":"codex","source":"local","historyCoverageIsEstablished":false,
        "daily":[{"date":"2026-09-30","inputTokens":1000,"cacheReadTokens":800,"outputTokens":100,"totalTokens":1100}],
        "totals":{"inputTokens":1000,"cacheReadTokens":800,"outputTokens":100,"totalTokens":1100}}
        """.utf8)
        let report = try JSONDecoder().decode(CodexCostReport.self, from: raw)
        XCTAssertEqual(report.historyCoverageIsEstablished, false)
        XCTAssertEqual(report.totals?.totalTokens, 1100)
        XCTAssertEqual(report.daily?.first?.cacheReadTokens, 800)
        let unavailable = try JSONDecoder().decode(CodexCostReport.self, from: Data("{\"provider\":\"codex\"}".utf8))
        XCTAssertNil(unavailable.totals)
        XCTAssertNil(unavailable.daily)
    }
}
