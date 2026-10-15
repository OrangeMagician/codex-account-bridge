import Foundation
import Testing
@testable import CABDesktop

@Suite("API equivalent estimates")
struct TokenCostTests {
    @Test func unknownUsageIsNotShownAsFreeAndTinyCostsStayVisible() {
        #expect(TokenCostAmount(usd: 0, pricedTokens: 0, unpricedTokens: 100).displayValue == cabLocalized("无法估算"))
        #expect(TokenCostAmount(usd: 0, pricedTokens: 0, unpricedTokens: 0).displayValue.contains("0"))
        #expect(TokenCostAmount(usd: 0.0001, pricedTokens: 100, unpricedTokens: 0).displayValue == "< US$0.01")
        #expect(TokenCostAmount(usd: .infinity, pricedTokens: 100, unpricedTokens: 0).displayValue == cabLocalized("无法估算"))
    }

    @Test func oldReportsRemainCompatibleAndNewReportsDecode() throws {
        let base = #"{"fetched_at":"2026-09-24T12:00:00Z","total_tokens":100,"max_daily_tokens":100,"active_days":1,"current_streak":1,"longest_streak":1,"thread_count":1,"daily":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(TokenUsageReport.self, from: Data(base.utf8)).costEstimate == nil)
        let cost = #"{"currency":"USD","basis":"standard_short_context_current_rates","rate_date":"2026-09-24","as_of_date":"2026-09-24","today":{"usd":1.56,"priced_tokens":100,"unpriced_tokens":0},"month":{"usd":1.56,"priced_tokens":100,"unpriced_tokens":0},"total":{"usd":1.56,"priced_tokens":100,"unpriced_tokens":0},"models":[{"model":"gpt-6-sol","usd":1.56,"priced_tokens":100,"unpriced_tokens":0}]}"#
        let data = Data((String(base.dropLast()) + ",\"cost_estimate\":" + cost + "}").utf8)
        let report = try decoder.decode(TokenUsageReport.self, from: data)
        #expect(report.costEstimate?.today.usd == 1.56)
        #expect(report.costEstimate?.models.first?.amount.pricedTokens == 100)
    }
}
