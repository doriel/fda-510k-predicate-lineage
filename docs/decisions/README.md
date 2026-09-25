# Decision records

Short records of design decisions: what we decided, why, and what it costs.
Each one links to the evidence behind it, mostly the extraction spike in
[`docs/spikes/2026-09-extraction-spike.md`](../spikes/2026-09-extraction-spike.md).

| # | Decision | Status |
|---|---|---|
| [0001](0001-ai-models-incremental-no-full-refresh.md) | dbt models that call AI functions are incremental, with full refresh disabled | Accepted |
| [0002](0002-parse-in-dbt-on-sql-warehouse.md) | Document parsing runs in dbt on a SQL warehouse | Accepted |
| [0003](0003-llm-extraction-regex-as-check.md) | Predicates are extracted by an LLM; regex is only a recall check | Accepted |
| [0004](0004-citation-model-and-resolution.md) | Citations carry an identifier type and a resolution status, validated in dbt | Accepted |
| [0005](0005-versioned-extractions.md) | Extractions are versioned and never overwritten | Accepted |
| [0006](0006-hand-labeled-evaluation-set.md) | Accuracy is measured against a hand-labeled evaluation set | Accepted |

Template for new records: Context, Decision, Consequences, Evidence.
