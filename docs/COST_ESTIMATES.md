# Estimated API equivalent

The Token usage section and `cab tokens [--account NAME] [--json]` report the
USD value of recorded tokens at a fixed snapshot of standard, short-context
OpenAI API rates. This is a comparison estimate, not a bill, remaining balance,
subscription allowance, or Credits conversion.

- Today and month use UTC, as do the existing activity statistics. `as_of_date`
  identifies the date of the calculation; refresh to update a report after midnight.
- Input includes cached input. Cost is `(input - cached) × input rate + cached ×
  cached rate + output × output rate`, divided by one million. Output already
  includes reasoning tokens.
- All history is valued at the rate snapshot updated **2026-10-13** (baseline verified September 24; GPT-6.1 Sol verified October 13), not historical
  transaction prices. The snapshot is bundled in `internal/codex/cost.go`; updates
  require an explicit source-verified code change, not a network request on refresh.
- This baseline excludes long-context/Fast premiums, cache writes, tools, image
  generation, voice, regional charges, and discounts. It cannot reconcile invoices.
- Model IDs come from each recorded `turn_context`, preserving model changes in a
  session. Unknown/missing model IDs and inconsistent counters stay unpriced.
  The report exposes priced and unpriced token counts for each period and model.
  A period with only unpriced usage displays “Unavailable”, not $0.
- The current machine's readable session history is the scope. `--account`
  restricts the homes scanned, not verified billing ownership. Imported/shared
  histories may have originated with another account. Existing event-level
  deduplication applies before both token and money aggregation.
- Missing/deleted/cloud-only records remain outside the report. Existing missing
  thread and incomplete file warnings still apply. No balances are inferred from
  quota percentages, and no authentication files are read by the statistics reader.
- The local counter cache now stores model IDs along with numeric counters and
  normalized timestamps. Old cache entries are rebuilt automatically. Message
  text, prompts and credentials are never retained in this cache.
- New desktop clients tolerate older remote CAB reports without `cost_estimate`;
  they prompt for a target update instead of inventing a zero estimate.

## Rate sources

[Official pricing](https://developers.openai.com/api/docs/pricing) and model pages:

- [GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol), with
  input/cached input/output rates of $2/$0.10/$10 per million tokens
- [GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra),
  [Sol](https://developers.openai.com/api/docs/models/gpt-6-sol),
  [Luna](https://developers.openai.com/api/docs/models/gpt-6-luna)
- [GPT-5.6 Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol),
  [Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra),
  [Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna)
- [GPT-5.5](https://developers.openai.com/api/docs/models/gpt-5.5),
  [GPT-5.4](https://developers.openai.com/api/docs/models/gpt-5.4),
  [GPT-5.4 mini](https://developers.openai.com/api/docs/models/gpt-5.4-mini)
- [GPT-5.3 Codex](https://developers.openai.com/api/docs/models/gpt-5.3-codex),
  [GPT-5.2 Codex](https://developers.openai.com/api/docs/models/gpt-5.2-codex)
