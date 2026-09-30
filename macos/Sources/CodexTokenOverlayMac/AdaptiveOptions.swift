import Foundation

struct AdaptiveOptions: Codable, Equatable, Sendable {
    var lower_percent: Double = 45
    var upper_percent: Double = 65
    var tiers: [Int64?] = [nil, nil, nil]

    static func parse(lower: String, upper: String, tiers: [String]) throws -> AdaptiveOptions {
        guard let low = Double(lower.trimmingCharacters(in: .whitespacesAndNewlines)),
              let high = Double(upper.trimmingCharacters(in: .whitespacesAndNewlines)),
              low.isFinite, high.isFinite, low >= 0, low < high, high <= 100 else {
            throw FocusedContextTarget.failure("阈值需满足 0 ≤ 两次阈值 < 一次阈值 ≤ 100。")
        }
        guard tiers.count == 3 else { throw FocusedContextTarget.failure("需要三个自适应档位。") }
        let amounts = try tiers.map { text -> Int64? in
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return nil }
            guard value.allSatisfy({ $0 >= "0" && $0 <= "9" }), let amount = Int64(value),
                  amount > 0, amount <= 9007199254740 else {
                throw FocusedContextTarget.failure("档位请输入正整数 K；留空跟随官方值。")
            }
            return amount * 1000
        }
        let supplied = amounts.compactMap { $0 }
        guard zip(supplied, supplied.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
            throw FocusedContextTarget.failure("自适应档位必须从小到大。")
        }
        return AdaptiveOptions(lower_percent: low, upper_percent: high, tiers: amounts)
    }
}
