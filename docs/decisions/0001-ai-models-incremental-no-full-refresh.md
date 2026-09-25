# 0001. AI models in dbt are incremental, with full refresh disabled

- Status: Accepted
- Date: 2026-09-25

## Context

The parse and extraction steps call `ai_parse_document` and `ai_query`. Each call
costs money and takes time: in the spike, parsing took about 2 seconds per
document in batch, and extraction took 17 to 60+ seconds per document depending
on the length of the predicate list. LLM output is also not deterministic, so
running the same document twice can give a different result.

In dbt, a model materialized as a view or table, or a `dbt run --full-refresh`,
would call the AI functions again on every document.

## Decision

- Models that call AI functions are materialized as `incremental`.
- They set `full_refresh: false`, so `--full-refresh` cannot rebuild them by accident.
- The incremental key is the document identity plus a content hash of the PDF
  (`k_number`, `content_sha256`), plus the parser or prompt version
  (see [0005](0005-versioned-extractions.md)).
- A document is processed again only when its content changes or a new
  version is deliberately introduced.

## Consequences

- Reprocessing is an explicit decision (a new version), never a side effect.
- Rebuilding the downstream models (resolution, marts, metrics) is cheap and
  safe, because they read stored AI output instead of calling the models.
- A genuine full rebuild of AI output requires a documented manual step.

## Evidence

- Spike timings: [spike write-up](../spikes/2026-09-extraction-spike.md#cost-and-time).
