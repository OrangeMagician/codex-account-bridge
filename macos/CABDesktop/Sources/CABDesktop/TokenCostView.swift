import SwiftUI

struct TokenCostAmount: Codable, Equatable {
    let usd: Double
    let pricedTokens: Int64
    let unpricedTokens: Int64

    enum CodingKeys: String, CodingKey {
        case usd
        case pricedTokens = "priced_tokens"
        case unpricedTokens = "unpriced_tokens"
    }

    var displayValue: String {
        guard usd.isFinite, usd >= 0, pricedTokens > 0 || unpricedTokens == 0 else {
            return cabLocalized("无法估算")
        }
        if usd > 0 && usd < 0.01 { return "< US$0.01" }
        return "US$" + usd.formatted(.number.precision(.fractionLength(2)))
    }
}

struct TokenModelCost: Codable, Equatable, Identifiable {
    let model: String
    let usd: Double
    let pricedTokens: Int64
    let unpricedTokens: Int64
    var id: String { model }
    var amount: TokenCostAmount { .init(usd: usd, pricedTokens: pricedTokens, unpricedTokens: unpricedTokens) }
    enum CodingKeys: String, CodingKey {
        case model, usd
        case pricedTokens = "priced_tokens"
        case unpricedTokens = "unpriced_tokens"
    }
}

struct TokenCostEstimate: Codable, Equatable {
    let currency: String
    let basis: String
    let rateDate: String
    let asOfDate: String
    let today: TokenCostAmount
    let month: TokenCostAmount
    let total: TokenCostAmount
    let models: [TokenModelCost]

    enum CodingKeys: String, CodingKey {
        case currency, basis, today, month, total, models
        case rateDate = "rate_date"
        case asOfDate = "as_of_date"
    }
}

struct TokenCostView: View {
    let estimate: TokenCostEstimate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(cabLocalized("预估 API 等值消耗")).font(.headline)
            if estimate.currency == "USD" && estimate.basis == "standard_short_context_current_rates" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .topLeading)], alignment: .leading, spacing: 10) {
                    amount("今日（UTC）", estimate.today)
                    amount("本月（UTC）", estimate.month)
                    amount("累计", estimate.total)
                }
                Text(cabLocalized("按标准短上下文 API 费率折算，仅供比较；不是实际账单或账号余额。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if estimate.total.unpricedTokens > 0 {
                    Label(String(format: cabLocalized("未计价 %@ Token，金额仅含已知模型的有效记录。"), TokenActivityData.formatted(estimate.total.unpricedTokens)), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(estimate.models) { model in
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline) {
                                    modelName(model)
                                    Spacer(minLength: 12)
                                    Text(model.amount.displayValue).monospacedDigit().fixedSize()
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    modelName(model)
                                    Text(model.amount.displayValue).monospacedDigit()
                                }
                            }
                        }
                        Text(String(format: cabLocalized("费率日期：%@；统计日期：%@（UTC）。历史用量也按这份费率折算。"), estimate.rateDate, estimate.asOfDate))
                        Text(cabLocalized("不含长上下文及加速溢价、缓存写入、工具、地区附加费或折扣。"))
                        Text(cabLocalized("范围为当前机器可读取的会话记录，共享历史去重；会话所在账号不代表实际付费账号。"))
                        Link(cabLocalized("查看官方 API 价格"), destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                } label: {
                    Text(cabLocalized("模型明细与估算说明"))
                }
                .font(.caption)
            } else {
                Text(cabLocalized("暂不支持此估算口径，请更新 CAB。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func modelName(_ model: TokenModelCost) -> some View {
        Text(model.model.isEmpty ? cabLocalized("未知模型") : model.model)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private func amount(_ title: String, _ cost: TokenCostAmount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cabLocalized(title)).font(.caption).foregroundStyle(.secondary)
            Text(cost.displayValue).font(.headline).monospacedDigit()
            if cost.unpricedTokens > 0 {
                Text(cabLocalized("部分用量未计价")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
