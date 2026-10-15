package codex

import (
	"math"
	"testing"
	"time"
)

func TestCostSeparatesCachedInputOutputAndUTCPeriods(t *testing.T) {
	now := time.Date(2026, 10, 1, 1, 0, 0, 0, time.FixedZone("UTC+8", 8*3600))
	report := estimateTokenCost([]ModelTokenUsage{
		{Date: "2026-09-30", Model: "gpt-6-sol", InputTokens: 1_000_000, CachedInputTokens: 800_000, OutputTokens: 100_000, TotalTokens: 1_100_000},
		{Date: "2026-09-01", Model: "gpt-6-luna", InputTokens: 1_000_000, OutputTokens: 1_000_000, TotalTokens: 2_000_000},
		{Date: "2026-08-31", Model: "gpt-5.5", InputTokens: 1_000_000, TotalTokens: 1_000_000},
	}, now)
	// 200k uncached * $2 + 800k cached * $.2 + 100k output * $10.
	if math.Abs(report.Today.USD-1.56) > 1e-9 || math.Abs(report.Month.USD-2.16) > 1e-9 || math.Abs(report.Total.USD-7.16) > 1e-9 {
		t.Fatalf("wrong cost or UTC boundaries: %+v", report)
	}
	if report.AsOfDate != "2026-09-30" || report.Total.PricedTokens != 4_100_000 || len(report.Models) != 3 {
		t.Fatalf("wrong coverage: %+v", report)
	}
}

func TestCostUnknownAndInvalidRecordsStayUnpriced(t *testing.T) {
	report := estimateTokenCost([]ModelTokenUsage{
		{Model: "gpt-6-sol-unverified", InputTokens: 10, TotalTokens: 10},
		{Model: "", InputTokens: 20, TotalTokens: 20},
		{Model: "gpt-6-sol", InputTokens: 10, CachedInputTokens: 11, TotalTokens: 10},
		{Model: "gpt-6-sol", InputTokens: 10, OutputTokens: 1, TotalTokens: 10},
	}, time.Now())
	if report.Total.USD != 0 || report.Total.PricedTokens != 0 || report.Total.UnpricedTokens != 50 {
		t.Fatalf("unknown usage was billed: %+v", report)
	}
	empty := estimateTokenCost(nil, time.Now())
	if empty.Models == nil || empty.Total.USD != 0 || empty.Total.UnpricedTokens != 0 {
		t.Fatal(empty)
	}
}

func TestSol61HasItsOwnCachedInputRateAndKeepsHistoricalModels(t *testing.T) {
	report := estimateTokenCost([]ModelTokenUsage{
		{Model: "gpt-6.1-sol", InputTokens: 1_000_000, CachedInputTokens: 800_000, OutputTokens: 100_000, TotalTokens: 1_100_000},
		{Model: "gpt-5.5", InputTokens: 1_000_000, TotalTokens: 1_000_000},
	}, time.Now())
	if math.Abs(report.Total.USD-6.48) > 1e-9 || report.Total.UnpricedTokens != 0 {
		t.Fatal(report)
	}
}
