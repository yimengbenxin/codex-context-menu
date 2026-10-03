import XCTest
import AppKit
import SwiftUI
import CodexTokenCore
@testable import CodexTokenOverlayMac

final class UsageDashboardTests: XCTestCase {
    func testMenuFormattingUsesUpstreamCompactUnitsAndCountdownRounding() throws {
        XCTAssertEqual(UsageFormat.menuTokens(999), "999")
        XCTAssertEqual(UsageFormat.menuTokens(1000), "1K")
        XCTAssertEqual(UsageFormat.menuTokens(999_500), "1M")
        XCTAssertEqual(UsageFormat.menuTokens(999_500_000), "1B")
        XCTAssertEqual(UsageFormat.menuTokens(nil), "未报告")
        XCTAssertEqual(UsageFormat.menuPercent(0.5), "<1%")
        XCTAssertEqual(UsageFormat.menuPercent(105), "100%")
        let window = try JSONDecoder().decode(CodexQuotaReport.Window.self, from: Data("{\"resetsAt\":\"1970-01-02T02:00:01Z\"}".utf8))
        let epoch = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(UsageFormat.menuReset(window, now: epoch), "1天 2小时后重置")
        XCTAssertEqual(UsageFormat.menuUpdated("1970-01-01T00:00:00Z", now: epoch), "刚刚更新")
    }

    @MainActor
    func testCodexBarCardUsesNativeGeometryAndPreservesMissingValues() {
        let model = UsageModel()
        let presentation = CodexBarCardPresentation(model)
        XCTAssertTrue(presentation.metrics.isEmpty)
        XCTAssertNil(presentation.credits)
        XCTAssertTrue(presentation.today.contains("未报告"))
        XCTAssertEqual(model.period, .month)
        XCTAssertEqual(CodexBarLayout.menuWidth, 310)
        XCTAssertEqual(CodexBarLayout.horizontalPadding, 20)
        XCTAssertEqual(CodexBarLayout.progressHeight, 6)
        let host = NSHostingView(rootView: CodexBarUsageCard(presentation: presentation).fixedSize(horizontal: false, vertical: true))
        XCTAssertEqual(host.fittingSize.width, 310, accuracy: 1)
        XCTAssertGreaterThan(host.fittingSize.height, 100)
        XCTAssertLessThan(host.fittingSize.height, 500)
    }

    @MainActor
    func testCodexBarCardBindsPercentPaceAndRedactsAccount() throws {
        let model = UsageModel()
        model.quota = try JSONDecoder().decode(CodexQuotaReport.self, from: Data("""
        {"provider":"codex","usage":{"accountEmail":"fixture@example.com","loginMethod":"Plus",
          "primary":{"usedPercent":12.5},"secondary":{"usedPercent":60,"isSyntheticPlaceholder":true}},
          "pace":{"primary":{"expectedUsedPercent":30,"deltaPercent":-17.5,"willLastToReset":true}},
          "credits":{"remaining":0,"balanceReadSucceeded":true}}
        """.utf8))
        let presentation = CodexBarCardPresentation(model)
        XCTAssertEqual(presentation.account, "f•••@example.com")
        XCTAssertEqual(presentation.plan, "Plus")
        XCTAssertEqual(presentation.metrics.count, 2)
        XCTAssertEqual(presentation.metrics[0].percent, 12.5)
        XCTAssertEqual(presentation.metrics[0].pace, 30)
        XCTAssertTrue(presentation.metrics[0].paceOnTop)
        XCTAssertNil(presentation.metrics[1].percent)
        XCTAssertEqual(presentation.credits, "0")
        model.quotaError = "refresh failed"
        XCTAssertEqual(CodexBarCardPresentation(model).error, "refresh failed")
    }

    func testCacheHitUsesInputNotTotalAndNeverAddsReasoningTwice() {
        let numbers = UsageNumbers(input: 1000, cached: 800, output: 200, reasoning: 100, total: 1200)
        XCTAssertEqual(numbers.cacheHitPercent, 80)
        XCTAssertEqual(numbers.uncached, 200)
        XCTAssertEqual(numbers.total, 1200)
        XCTAssertNil(UsageNumbers(input: 0, cached: 0, output: nil, reasoning: nil).cacheHitPercent)
        XCTAssertNil(UsageNumbers(input: 100, cached: 101, output: nil, reasoning: nil).uncached)
        XCTAssertNil(UsageNumbers(input: nil, cached: 0, output: nil, reasoning: nil).cacheHitPercent)
        XCTAssertEqual(UsageFormat.tokens(nil), "未报告")
        XCTAssertEqual(UsageFormat.money(nil), "未报告")
        XCTAssertEqual(UsageFormat.percent(.nan), "未报告")
    }

    func testBackendPeriodArgumentsAndNativeDataContract() throws {
        for period in UsagePeriod.allCases {
            let arguments = UsageBackend.costArguments(period: period, refresh: false)
            XCTAssertTrue(arguments.contains("--provider-native-only"))
            XCTAssertFalse(arguments.contains("--refresh"))
            XCTAssertEqual(Array(arguments.suffix(2)), period.arguments)
        }
        XCTAssertTrue(UsageBackend.costArguments(period: .month, refresh: true).contains("--refresh"))
        let partial = try UsageBackend.decodeQuota(Data("""
        [{"provider":"codex","credits":{"remaining":0,"balanceReadSucceeded":true}}]
        """.utf8))
        XCTAssertNil(partial.usage)
        XCTAssertEqual(partial.credits?.remaining, 0)
        XCTAssertThrowsError(try UsageBackend.decodeQuota(Data("""
        [{"provider":"codex","usage":{"primary":{"usedPercent":10}},"error":{"message":"expired"}}]
        """.utf8)))
        XCTAssertThrowsError(try UsageBackend.decodeCost(Data("""
        [{"provider":"codex","error":{"message":"read failed"}}]
        """.utf8)))
    }

    @MainActor
    func testPeriodChangesDiscardOldResultAndUseOnlyLatestSelection() async throws {
        let reader = BlockingCostReader()
        let model = UsageModel(costReader: { period, refresh in try reader.read(period, refresh) })
        model.refreshCost()
        try await eventually { reader.requests.count == 1 }
        model.period = .week
        model.period = .all
        reader.release.signal()
        try await eventually { !model.costBusy && model.costPeriod == .all }
        XCTAssertEqual(reader.requests, [.month, .all])
        XCTAssertEqual(model.cost?.totals?.totalTokens, 40)
        XCTAssertNil(model.costError)
    }

    @MainActor
    func testFailedRefreshKeepsLastSnapshotAndLabelsItStale() async throws {
        let reader = BlockingCostReader()
        reader.release.signal()
        let model = UsageModel(costReader: { period, refresh in try reader.read(period, refresh) })
        model.refreshCost(refresh: true)
        try await eventually { !model.costBusy && model.cost != nil }
        reader.fail = true
        model.refreshCost()
        try await eventually { !model.costBusy && model.costError != nil }
        XCTAssertEqual(model.costPeriod, .month)
        XCTAssertEqual(model.cost?.totals?.totalTokens, 40)
        XCTAssertEqual(reader.refreshes.first, true)
    }

    @MainActor
    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected state transition did not complete")
    }
}

private final class BlockingCostReader: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recorded: [UsagePeriod] = []
    private var forced: [Bool] = []
    private var failure = false
    var requests: [UsagePeriod] { lock.withLock { recorded } }
    var refreshes: [Bool] { lock.withLock { forced } }
    var fail: Bool {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    func read(_ period: UsagePeriod, _ refresh: Bool) throws -> CodexCostReport {
        let first = lock.withLock {
            recorded.append(period)
            forced.append(refresh)
            return recorded.count == 1
        }
        if first { _ = release.wait(timeout: .now() + 3) }
        if fail { throw NSError(domain: "fixture", code: 1) }
        let value = period == .week ? 10 : 40
        return try JSONDecoder().decode(CodexCostReport.self, from: Data("{\"provider\":\"codex\",\"totals\":{\"totalTokens\":\(value)}}".utf8))
    }
}
