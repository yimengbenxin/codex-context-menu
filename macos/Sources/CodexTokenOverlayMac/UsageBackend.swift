import Foundation
import CodexTokenCore

enum UsageBackend {
    static func binary() throws -> String {
        guard let resources = Bundle.main.resourceURL else {
            throw NSError(domain: "Usage", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到用量组件，请重新安装工具。"])
        }
        return resources.appendingPathComponent("usage/CodexBarCLI").path
    }

    static func cost(period: UsagePeriod = .week, refresh: Bool = false) throws -> CodexCostReport {
        guard let resources = Bundle.main.resourceURL else {
            throw NSError(domain: "Usage", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到用量组件，请重新安装工具。"])
        }
        let data = try LocalCommand.run("/usr/bin/sandbox-exec", costSandboxArguments(resources: resources) + [
            try binary()] + costArguments(period: period, refresh: refresh), allowFailure: true)
        return try decodeCost(data)
    }

    static func costArguments(period: UsagePeriod, refresh: Bool) -> [String] {
        ["cost", "--provider", "codex", "--provider-native-only", "--format", "json"] + period.arguments + (refresh ? ["--refresh"] : [])
    }

    static func decodeCost(_ data: Data) throws -> CodexCostReport {
        guard let report = try JSONDecoder().decode([CodexCostReport].self, from: data).first(where: { $0.provider == "codex" }) else {
            throw NSError(domain: "Usage", code: 2, userInfo: [NSLocalizedDescriptionKey: "统计组件未返回 Codex 数据。"])
        }
        if let failure = report.error {
            throw NSError(domain: "Usage", code: 3, userInfo: [NSLocalizedDescriptionKey: failure.message])
        }
        return report
    }

    static func costSandboxArguments(resources: URL) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var cachePath = [CChar](repeating: 0, count: Int(PATH_MAX))
        _ = confstr(_CS_DARWIN_USER_CACHE_DIR, &cachePath, cachePath.count)
        let paths = ["HOME": home.path, "RESOURCES": resources.path,
            "CODEX_HOME": SessionPathResolver.resolveCodexHome(),
            "COST_CACHE": home.appendingPathComponent("Library/Caches/CodexBar").path,
            "CLI_CACHE": home.appendingPathComponent("Library/Caches/CodexBarCLI").path,
            "RUNTIME_CACHE": URL(fileURLWithPath: String(cString: cachePath)).appendingPathComponent("CodexBarCLI").resolvingSymlinksInPath().path,
            "PREFERENCES": home.appendingPathComponent("Library/Preferences").path,
            "TEMPORARY": FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path]
        return paths.sorted(by: { $0.key < $1.key }).flatMap { ["-D", "\($0.key)=\($0.value)"] }
            + ["-f", resources.appendingPathComponent("usage/cost-history.sb").path]
    }

    static func quota() throws -> CodexQuotaReport {
        let data = try LocalCommand.run(try binary(), ["usage", "--provider", "codex", "--source", "oauth",
            "--format", "json"], allowFailure: true)
        return try decodeQuota(data)
    }

    static func decodeQuota(_ data: Data) throws -> CodexQuotaReport {
        let report = try JSONDecoder().decode([CodexQuotaReport].self, from: data).first(where: { $0.provider == "codex" })
        guard let report, report.error == nil, report.usage != nil || report.credits != nil else {
            let message = report?.error?.message ?? "官方未返回账号额度，请先在 Codex 中登录。"
            throw NSError(domain: "Usage", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return report
    }
}
