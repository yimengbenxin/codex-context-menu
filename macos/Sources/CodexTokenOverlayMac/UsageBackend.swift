import Foundation
import CodexTokenCore

enum UsageBackend {
    static func binary() throws -> String {
        guard let resources = Bundle.main.resourceURL else {
            throw NSError(domain: "Usage", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到用量组件，请重新安装工具。"])
        }
        return resources.appendingPathComponent("usage/CodexBarCLI").path
    }

    static func cost() throws -> CodexCostReport {
        let data = try LocalCommand.run("/usr/bin/sandbox-exec", ["-p", "(version 1)(allow default)(deny network*)",
            try binary(), "cost", "--provider", "codex", "--provider-native-only", "--days", "7", "--format", "json"], allowFailure: true)
        guard let report = try JSONDecoder().decode([CodexCostReport].self, from: data).first(where: { $0.provider == "codex" }) else {
            throw NSError(domain: "Usage", code: 2, userInfo: [NSLocalizedDescriptionKey: "统计组件未返回 Codex 数据。"])
        }
        if let failure = report.error {
            throw NSError(domain: "Usage", code: 3, userInfo: [NSLocalizedDescriptionKey: failure.message])
        }
        return report
    }

    static func quota() throws -> CodexQuotaReport {
        let data = try LocalCommand.run(try binary(), ["usage", "--provider", "codex", "--source", "oauth",
            "--format", "json", "--no-credits"], allowFailure: true)
        guard let report = try JSONDecoder().decode([CodexQuotaReport].self, from: data).first(where: { $0.provider == "codex" }), report.usage != nil else {
            let reports = try JSONDecoder().decode([CodexQuotaReport].self, from: data)
            let message = reports.first?.error?.message ?? "官方未返回账号额度，请先在 Codex 中登录。"
            throw NSError(domain: "Usage", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return report
    }
}
