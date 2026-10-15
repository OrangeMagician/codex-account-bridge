package codex

import (
	"sort"
	"time"
)

// Standard, short-context USD rates per million tokens. Baseline verified
// 2026-09-24 against https://developers.openai.com/api/docs/pricing and each
// https://developers.openai.com/api/docs/models/<model> page. This is a
// comparable token value, never an invoice or a subscription balance.
// Exact IDs only: an unknown model must not inherit another model's rate.
var standardTokenRates = map[string][3]float64{
	// GPT-6.1 Sol verified 2026-10-13 against its official model page.
	"gpt-6.1-sol":   {2, .1, 10},
	"gpt-6-astra":   {10, 1, 50},
	"gpt-6-sol":     {2, .2, 10},
	"gpt-6-luna":    {.1, .01, .5},
	"gpt-5.6-sol":   {4, .4, 20},
	"gpt-5.6-terra": {2, .2, 12},
	"gpt-5.6-luna":  {.2, .02, 1.2},
	"gpt-5.5":       {5, .5, 30},
	"gpt-5.4":       {2.5, .25, 15},
	"gpt-5.4-mini":  {.75, .075, 4.5},
	"gpt-5.3-codex": {1.75, .175, 14},
	"gpt-5.2-codex": {1.75, .175, 14},
}

type ModelTokenUsage struct {
	Date              string `json:"date"`
	Model             string `json:"model"`
	InputTokens       int64  `json:"input_tokens"`
	CachedInputTokens int64  `json:"cached_input_tokens"`
	OutputTokens      int64  `json:"output_tokens"`
	TotalTokens       int64  `json:"total_tokens"`
}

type CostAmount struct {
	USD            float64 `json:"usd"`
	PricedTokens   int64   `json:"priced_tokens"`
	UnpricedTokens int64   `json:"unpriced_tokens"`
}

type ModelCost struct {
	Model string `json:"model"`
	CostAmount
}

type TokenCostEstimate struct {
	Currency  string      `json:"currency"`
	Basis     string      `json:"basis"`
	RateDate  string      `json:"rate_date"`
	SourceURL string      `json:"source_url"`
	AsOfDate  string      `json:"as_of_date"`
	Today     CostAmount  `json:"today"`
	Month     CostAmount  `json:"month"`
	Total     CostAmount  `json:"total"`
	Models    []ModelCost `json:"models"`
}

func (c *CostAmount) add(other CostAmount) {
	c.USD += other.USD
	c.PricedTokens += other.PricedTokens
	c.UnpricedTokens += other.UnpricedTokens
}

func estimateTokenCost(rows []ModelTokenUsage, now time.Time) *TokenCostEstimate {
	today := now.UTC().Format("2006-01-02")
	result := &TokenCostEstimate{
		Currency: "USD", Basis: "standard_short_context_current_rates",
		RateDate: "2026-10-13", SourceURL: "https://developers.openai.com/api/docs/pricing",
		AsOfDate: today, Models: []ModelCost{},
	}
	models := map[string]CostAmount{}
	for _, row := range rows {
		amount := CostAmount{}
		rates, known := standardTokenRates[row.Model]
		if known && row.InputTokens >= 0 && row.CachedInputTokens >= 0 && row.CachedInputTokens <= row.InputTokens && row.OutputTokens >= 0 && row.InputTokens+row.OutputTokens == row.TotalTokens {
			amount.USD = (float64(row.InputTokens-row.CachedInputTokens)*rates[0] + float64(row.CachedInputTokens)*rates[1] + float64(row.OutputTokens)*rates[2]) / 1_000_000
			amount.PricedTokens = row.TotalTokens
		} else {
			amount.UnpricedTokens = row.TotalTokens
		}
		result.Total.add(amount)
		if row.Date == today {
			result.Today.add(amount)
		}
		if len(row.Date) == 10 && row.Date[:7] == today[:7] && row.Date <= today {
			result.Month.add(amount)
		}
		model := models[row.Model]
		model.add(amount)
		models[row.Model] = model
	}
	for name, cost := range models {
		result.Models = append(result.Models, ModelCost{Model: name, CostAmount: cost})
	}
	sort.Slice(result.Models, func(i, j int) bool { return result.Models[i].Model < result.Models[j].Model })
	return result
}
