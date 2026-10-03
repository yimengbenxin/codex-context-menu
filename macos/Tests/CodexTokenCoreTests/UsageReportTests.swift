import XCTest
@testable import CodexTokenCore

final class UsageReportTests: XCTestCase {
    func testNativeCostPayloadPreservesAllFields() throws {
        let raw = Data("""
        [{"provider":"codex","source":"local","updatedAt":"2026-10-01T00:00:00Z",
        "currencyCode":"USD","sessionTokens":5000000000,"sessionCostUSD":0.5,"historyDays":30,
        "reportingPeriod":"last30Days","historyLabel":"30 days","historyCoverageIsEstablished":false,
        "last30DaysTokens":6000000000,"last30DaysCostUSD":12.5,"meteredCostUSD":2.5,
        "provenance":"estimated","coverage":{"priced":1,"unpriced":2,"unmetered":3,"estimated":4},
        "incompleteRequestCount":2,
        "totals":{"inputTokens":100,"outputTokens":20,"cacheReadTokens":50,"cacheCreationTokens":10,
        "reasoningTokens":5,"totalTokens":120,"totalCost":0.25,"provenance":"estimated",
        "coverage":{"priced":4,"unpriced":3,"unmetered":2,"estimated":1},"incompleteRequestCount":1},
        "daily":[{"date":"2026-10-01","inputTokens":100,"outputTokens":20,"cacheReadTokens":50,
        "cacheCreationTokens":10,"reasoningTokens":5,"totalTokens":120,"totalCost":0.25,
        "modelsUsed":["gpt-6.1-sol"],"incompleteRequestCount":1,
        "modelBreakdowns":[{"modelName":"gpt-6.1-sol","totalTokens":120,"cost":0.25,"incompleteRequestCount":1}]}],
        "projects":[{"name":"demo","path":"/tmp/demo","totalTokens":120,"totalCost":0.25,
        "daily":[{"date":"2026-10-01","totalTokens":120,"totalCost":0.25}],
        "modelBreakdowns":[{"modelName":"gpt-6.1-sol","totalTokens":120,"cost":0.25}],
        "sources":[{"name":"cli","path":"/tmp/demo/session.jsonl","totalTokens":120,"totalCost":0.25,
        "daily":[{"date":"2026-10-01","totalTokens":120,"totalCost":0.25}],
        "modelBreakdowns":[{"modelName":"gpt-6.1-sol","totalTokens":120,"cost":0.25}]}]}],
        "error":{"code":2,"kind":"provider","message":"partial"},"futureField":true}]
        """.utf8)
        let report = try XCTUnwrap(JSONDecoder().decode([CodexCostReport].self, from: raw).first)
        XCTAssertEqual(report.provider, "codex")
        XCTAssertEqual(report.source, "local")
        XCTAssertEqual(report.updatedAt, "2026-10-01T00:00:00Z")
        XCTAssertEqual(report.currencyCode, "USD")
        XCTAssertEqual(report.sessionTokens, 5000000000)
        XCTAssertEqual(report.sessionCostUSD, 0.5)
        XCTAssertEqual(report.historyDays, 30)
        XCTAssertEqual(report.reportingPeriod, "last30Days")
        XCTAssertEqual(report.historyLabel, "30 days")
        XCTAssertEqual(report.historyCoverageIsEstablished, false)
        XCTAssertEqual(report.last30DaysTokens, 6000000000)
        XCTAssertEqual(report.last30DaysCostUSD, 12.5)
        XCTAssertEqual(report.meteredCostUSD, 2.5)
        XCTAssertEqual(report.provenance, "estimated")
        XCTAssertEqual(report.coverage?.priced, 1)
        XCTAssertEqual(report.coverage?.unpriced, 2)
        XCTAssertEqual(report.coverage?.unmetered, 3)
        XCTAssertEqual(report.coverage?.estimated, 4)
        XCTAssertEqual(report.incompleteRequestCount, 2)
        let totals = try XCTUnwrap(report.totals)
        XCTAssertEqual(totals.inputTokens, 100)
        XCTAssertEqual(totals.outputTokens, 20)
        XCTAssertEqual(totals.cacheReadTokens, 50)
        XCTAssertEqual(totals.cacheCreationTokens, 10)
        XCTAssertEqual(totals.reasoningTokens, 5)
        XCTAssertEqual(totals.totalTokens, 120)
        XCTAssertEqual(totals.totalCost, 0.25)
        XCTAssertEqual(totals.provenance, "estimated")
        XCTAssertEqual(totals.coverage?.priced, 4)
        XCTAssertEqual(totals.coverage?.unpriced, 3)
        XCTAssertEqual(totals.coverage?.unmetered, 2)
        XCTAssertEqual(totals.coverage?.estimated, 1)
        XCTAssertEqual(totals.incompleteRequestCount, 1)
        let day = try XCTUnwrap(report.daily?.first)
        XCTAssertEqual(day.id, "2026-10-01")
        XCTAssertEqual(day.inputTokens, 100)
        XCTAssertEqual(day.outputTokens, 20)
        XCTAssertEqual(day.cacheReadTokens, 50)
        XCTAssertEqual(day.cacheCreationTokens, 10)
        XCTAssertEqual(day.reasoningTokens, 5)
        XCTAssertEqual(day.totalTokens, 120)
        XCTAssertEqual(day.totalCost, 0.25)
        XCTAssertEqual(day.modelsUsed, ["gpt-6.1-sol"])
        XCTAssertEqual(day.incompleteRequestCount, 1)
        XCTAssertEqual(day.modelBreakdowns?.first?.modelName, "gpt-6.1-sol")
        XCTAssertEqual(day.modelBreakdowns?.first?.cost, 0.25)
        XCTAssertEqual(day.modelBreakdowns?.first?.totalTokens, 120)
        XCTAssertEqual(day.modelBreakdowns?.first?.incompleteRequestCount, 1)
        let project = try XCTUnwrap(report.projects?.first)
        XCTAssertEqual(project.name, "demo")
        XCTAssertEqual(project.path, "/tmp/demo")
        XCTAssertEqual(project.totalTokens, 120)
        XCTAssertEqual(project.totalCost, 0.25)
        XCTAssertEqual(project.daily?.first?.totalTokens, 120)
        XCTAssertEqual(project.modelBreakdowns?.first?.cost, 0.25)
        let source = try XCTUnwrap(project.sources?.first)
        XCTAssertEqual(source.name, "cli")
        XCTAssertEqual(source.path, "/tmp/demo/session.jsonl")
        XCTAssertEqual(source.totalTokens, 120)
        XCTAssertEqual(source.totalCost, 0.25)
        XCTAssertEqual(source.daily?.first?.totalCost, 0.25)
        XCTAssertEqual(source.modelBreakdowns?.first?.modelName, "gpt-6.1-sol")
        XCTAssertEqual(report.error?.code, 2)
        XCTAssertEqual(report.error?.kind, "provider")
        XCTAssertEqual(report.error?.message, "partial")
    }

    func testNativeQuotaPayloadPreservesNestedContracts() throws {
        let raw = Data("""
        [{"provider":"codex","source":"oauth","account":"work","version":"0.69.0","diagnostic":"partial",
        "status":{"indicator":"none","description":"Operational","updatedAt":"2026-10-01T00:00:00Z","url":"https://status.openai.com"},
        "rateWindowLabels":{"primary":"Session","secondary":"Weekly","tertiary":"Review"},
        "usage":{"primary":{"usedPercent":105,"windowMinutes":300,"resetDescription":"in 2h",
        "resetsAt":"2026-10-01T02:00:00Z","nextRegenPercent":2,"isSyntheticPlaceholder":false},
        "secondary":{"usedPercent":0},"tertiary":{"usedPercent":25},"updatedAt":"2026-10-01T00:00:00Z",
        "accountEmail":"legacy@example.invalid","accountOrganization":"workspace","loginMethod":"plus",
        "identity":{"providerID":"codex","accountEmail":"native@example.invalid","accountOrganization":"workspace",
        "loginMethod":"pro","accountID":"account-id"},
        "extraRateWindows":[{"id":"spark","title":"Spark","window":{"usedPercent":70},"usageKnown":false}],
        "providerCost":{"used":2,"limit":10,"currencyCode":"USD","period":"Monthly",
        "resetsAt":"2026-11-01T00:00:00Z","nextRegenAmount":1,"personalUsed":0.5,"balance":8,
        "balanceUpdatedAt":"2026-10-01T00:00:00Z","balanceIsWorkspace":true,
        "updatedAt":"2026-10-01T00:00:00Z","balanceIsUnavailable":false}},
        "pace":{"primary":{"stage":"ahead","deltaPercent":5,"expectedUsedPercent":20,
        "willLastToReset":false,"etaSeconds":3600,"runOutProbability":null,"summary":"Ahead"},
        "secondary":{"stage":"onTrack","deltaPercent":0,"expectedUsedPercent":0,"willLastToReset":true,"summary":"On track"},
        "tertiary":{"stage":"behind","deltaPercent":-5,"expectedUsedPercent":30,"willLastToReset":true,"summary":"Reserve"}},
        "credits":{"remaining":0,"updatedAt":"2026-10-01T00:00:00Z","balanceReadSucceeded":false,
        "creditsAvailable":true,"balanceIsWorkspace":false,
        "events":[{"id":"00000000-0000-0000-0000-000000000001","date":"2026-10-01T00:00:00Z","service":"codex","creditsUsed":2}],
        "codexCreditLimit":{"title":"Monthly credit limit","used":2,"limit":10,"remaining":8,
        "remainingPercent":80,"resetsAt":"2026-11-01T00:00:00Z","updatedAt":"2026-10-01T00:00:00Z"}},
        "openaiDashboard":{"unknown":"ignored"},"token":"ignored","request":{"secret":"ignored"}}]
        """.utf8)
        let report = try XCTUnwrap(JSONDecoder().decode([CodexQuotaReport].self, from: raw).first)
        XCTAssertEqual(report.account, "work")
        XCTAssertEqual(report.version, "0.69.0")
        XCTAssertEqual(report.diagnostic, "partial")
        XCTAssertEqual(report.status?.indicator, "none")
        XCTAssertEqual(report.status?.description, "Operational")
        XCTAssertEqual(report.status?.updatedAt, "2026-10-01T00:00:00Z")
        XCTAssertEqual(report.status?.url, "https://status.openai.com")
        XCTAssertEqual(report.rateWindowLabels?.primary, "Session")
        XCTAssertEqual(report.rateWindowLabels?.secondary, "Weekly")
        XCTAssertEqual(report.rateWindowLabels?.tertiary, "Review")
        let usage = try XCTUnwrap(report.usage)
        XCTAssertEqual(usage.primary?.usedPercent, 105)
        XCTAssertEqual(usage.primary?.remainingPercent, 0)
        XCTAssertEqual(usage.secondary?.remainingPercent, 100)
        XCTAssertEqual(usage.tertiary?.remainingPercent, 75)
        XCTAssertEqual(usage.primary?.windowMinutes, 300)
        XCTAssertEqual(usage.primary?.resetDescription, "in 2h")
        XCTAssertEqual(usage.primary?.resetsAt, "2026-10-01T02:00:00Z")
        XCTAssertEqual(usage.primary?.nextRegenPercent, 2)
        XCTAssertEqual(usage.primary?.isSyntheticPlaceholder, false)
        XCTAssertEqual(usage.updatedAt, "2026-10-01T00:00:00Z")
        XCTAssertEqual(usage.loginMethod, "plus")
        XCTAssertEqual(usage.accountOrganization, "workspace")
        XCTAssertEqual(usage.identity?.providerID, "codex")
        XCTAssertEqual(usage.identity?.loginMethod, "pro")
        XCTAssertEqual(usage.identity?.accountOrganization, "workspace")
        XCTAssertEqual(usage.redactedAccount, "n•••@example.invalid")
        XCTAssertEqual(usage.extraRateWindows?.first?.id, "spark")
        XCTAssertEqual(usage.extraRateWindows?.first?.title, "Spark")
        XCTAssertEqual(usage.extraRateWindows?.first?.window.usedPercent, 70)
        XCTAssertEqual(usage.extraRateWindows?.first?.usageKnown, false)
        let cost = try XCTUnwrap(usage.providerCost)
        XCTAssertEqual(cost.used, 2)
        XCTAssertEqual(cost.limit, 10)
        XCTAssertEqual(cost.currencyCode, "USD")
        XCTAssertEqual(cost.period, "Monthly")
        XCTAssertEqual(cost.resetsAt, "2026-11-01T00:00:00Z")
        XCTAssertEqual(cost.nextRegenAmount, 1)
        XCTAssertEqual(cost.personalUsed, 0.5)
        XCTAssertEqual(cost.balance, 8)
        XCTAssertEqual(cost.balanceUpdatedAt, "2026-10-01T00:00:00Z")
        XCTAssertEqual(cost.balanceIsWorkspace, true)
        XCTAssertEqual(cost.balanceIsUnavailable, false)
        XCTAssertEqual(cost.updatedAt, "2026-10-01T00:00:00Z")
        XCTAssertEqual(report.pace?.primary?.stage, "ahead")
        XCTAssertEqual(report.pace?.primary?.deltaPercent, 5)
        XCTAssertEqual(report.pace?.primary?.expectedUsedPercent, 20)
        XCTAssertEqual(report.pace?.primary?.willLastToReset, false)
        XCTAssertEqual(report.pace?.primary?.etaSeconds, 3600)
        XCTAssertNil(report.pace?.primary?.runOutProbability)
        XCTAssertEqual(report.pace?.primary?.summary, "Ahead")
        XCTAssertEqual(report.pace?.secondary?.stage, "onTrack")
        XCTAssertEqual(report.pace?.tertiary?.deltaPercent, -5)
        let credits = try XCTUnwrap(report.credits)
        XCTAssertEqual(credits.remaining, 0)
        XCTAssertEqual(credits.balanceReadSucceeded, false)
        XCTAssertEqual(credits.creditsAvailable, true)
        XCTAssertEqual(credits.balanceIsWorkspace, false)
        XCTAssertEqual(credits.updatedAt, "2026-10-01T00:00:00Z")
        XCTAssertEqual(credits.events?.first?.id, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(credits.events?.first?.date, "2026-10-01T00:00:00Z")
        XCTAssertEqual(credits.events?.first?.service, "codex")
        XCTAssertEqual(credits.events?.first?.creditsUsed, 2)
        XCTAssertEqual(credits.codexCreditLimit?.title, "Monthly credit limit")
        XCTAssertEqual(credits.codexCreditLimit?.used, 2)
        XCTAssertEqual(credits.codexCreditLimit?.limit, 10)
        XCTAssertEqual(credits.codexCreditLimit?.remaining, 8)
        XCTAssertEqual(credits.codexCreditLimit?.remainingPercent, 80)
        XCTAssertEqual(credits.codexCreditLimit?.resetsAt, "2026-11-01T00:00:00Z")
        XCTAssertEqual(credits.codexCreditLimit?.updatedAt, "2026-10-01T00:00:00Z")
    }

    func testUnknownAndMissingFieldsRemainUnknown() throws {
        let quota = try JSONDecoder().decode(CodexQuotaReport.self, from: Data("""
        {"provider":"codex","usage":{"primary":{},"extraRateWindows":[{"id":"future","title":"Future","window":{}}],
        "providerCost":{},"identity":{},"future":true},"pace":{"primary":{}},"credits":{},"future":true}
        """.utf8))
        XCTAssertNil(quota.usage?.primary?.remainingPercent)
        XCTAssertNil(quota.usage?.primary?.isSyntheticPlaceholder)
        XCTAssertNil(quota.usage?.extraRateWindows?.first?.usageKnown)
        XCTAssertNil(quota.usage?.providerCost?.used)
        XCTAssertNil(quota.usage?.redactedAccount)
        XCTAssertNil(quota.pace?.primary?.deltaPercent)
        XCTAssertNil(quota.credits?.remaining)
        XCTAssertNil(quota.credits?.balanceReadSucceeded)
        let cost = try JSONDecoder().decode(CodexCostReport.self, from: Data("""
        {"provider":"codex","totals":{"coverage":{}},"daily":[{"date":"2026-10-01"}],"future":true}
        """.utf8))
        XCTAssertNil(cost.totals?.coverage?.priced)
        XCTAssertNil(cost.totals?.cacheCreationTokens)
        XCTAssertNil(cost.totals?.totalCost)
        XCTAssertNil(cost.daily?.first?.reasoningTokens)
        XCTAssertNil(cost.daily?.first?.modelBreakdowns)
        XCTAssertNil(cost.projects)
        XCTAssertThrowsError(try JSONDecoder().decode(CodexCostReport.self, from: Data("""
        {"provider":"codex","sessionTokens":"wrong-type"}
        """.utf8)))
    }

    func testSyntheticOrInvalidWindowsAreNotDisplayedAsUnusedQuota() throws {
        for value in ["\"usedPercent\":0,\"isSyntheticPlaceholder\":true", "\"usedPercent\":-1"] {
            let report = try JSONDecoder().decode(CodexQuotaReport.self, from: Data("{\"provider\":\"codex\",\"usage\":{\"primary\":{\(value)}}}".utf8))
            XCTAssertNil(report.usage?.primary?.remainingPercent)
        }
    }

    func testMissingQuotaIsNotReportedAsZeroAndIdentityIsRedacted() throws {
        let raw = Data("""
        {"provider":"codex","source":"oauth","usage":{"primary":null,
        "secondary":{"usedPercent":6,"windowMinutes":10080,"resetsAt":"2026-10-07T00:00:00Z"},
        "accountEmail":"someone@example.invalid","updatedAt":"2026-09-30T00:00:00Z"}}
        """.utf8)
        let report = try JSONDecoder().decode(CodexQuotaReport.self, from: raw)
        XCTAssertNil(report.usage?.primary)
        XCTAssertEqual(report.usage?.secondary?.remainingPercent, 94)
        XCTAssertEqual(report.usage?.redactedAccount, "s•••@example.invalid")
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
