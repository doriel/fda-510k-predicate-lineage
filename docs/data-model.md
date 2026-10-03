# Data model

The physical model as built. It started from the
[extraction spike](spikes/2026-09-extraction-spike.md) and the
[decision records](decisions/README.md); the last section lists what was
planned but not built yet.

Catalog and schema are variables (bundle variables and the dbt profile, both
read from `.env`), so the project runs in any workspace. Every table gets the
prefix `fda_` (dbt macro `generate_alias_name`), so it can share a schema with
other projects. Names below omit catalog, schema and prefix.

## Flow

```
openFDA bulk export ─► bronze_openfda_510k ─► stg_openfda__submissions ──────────────┐
                                                                                     │
PDF download ─► Volume ─► bronze_pdf_files ─► stg_pdf_files                          │
                                                   │                                 │
                                                   ▼                                 │
                                         int_documents_parsed (ai_parse_document)    │
                                                   │                                 │
                                                   ▼                                 │
                                         int_predicate_extractions (ai_query)        │
                                                   │                                 │
                                                   ▼                                 │
                                         int_predicate_citations                     │
                                           │              │                          │
                                           │              ▼                          │
                                           │   int_name_match_candidates ◄───────────┤
                                           │              │                          │
                                           │              ▼                          │
                                           │   int_name_resolution                   │
                                           ▼              │                          │
                                         int_predicate_resolution ◄──────────────────┘
                                                   │
                                                   ▼
                                         fct_predicate_edge ─────────┐
                                                                     ▼
int_documents_parsed ─► int_extraction_recall_gaps ─────► mart_extraction_quality ─► dashboard
                                                                     ▲
                              seeds: recall_gap_review, name_match_review
```

Python tasks own the bronze tables. dbt owns everything after that. One
Databricks job runs both every day (see the README, Orchestration).

## Bronze (Python tasks)

### `bronze_openfda_510k`
Grain: one row per K-number per openFDA export.

| Column | Type | Notes |
|---|---|---|
| `k_number` | string | |
| `raw` | variant | Full openFDA record |
| `export_date` | date | Export the record came from; a run loads a new export only when openFDA publishes one |

### `bronze_pdf_files`
Grain: one row per K-number in the sample (one download attempt each).

| Column | Notes |
|---|---|
| `k_number` | From the sample |
| `path`, `source_url` | Volume path and accessdata.fda.gov URL |
| `content_sha256`, `length` | Changes only if FDA replaces the file |
| `download_status` | `ok`, `http_404`, ... Failed attempts are recorded, not dropped, and never retried by the daily run |

## Staging (dbt, views)

- `stg_openfda__submissions`: one row per K-number from the latest export, typed fields
  (`decision_date`, `applicant`, `device_name`, `product_code`, `review_panel`,
  `statement_or_summary`, ...). Covers all 510(k)s, not only the sample, because
  predicates can come from any product code.
- `stg_pdf_files`: one row per K-number in the sample, with its download status.

## Intermediate (dbt)

### `int_documents_parsed`
Incremental, `full_refresh: false` ([0001](decisions/0001-ai-models-incremental-no-full-refresh.md)).
Grain: `k_number`, `content_sha256`, `parser_version`.
Raw `ai_parse_document` output, `parse_error`, page and element counts, and
`doc_text`, the input to extraction. Each run parses at most
`parse_batch_limit` new documents.

### `int_predicate_extractions`
Incremental, `full_refresh: false`.
Grain: `k_number`, `content_sha256`, `parser_version`, `prompt_version`, `model_endpoint`
([0005](decisions/0005-versioned-extractions.md)).
Raw JSON from `ai_query` with a JSON schema, `error_message`, and extraction
notes. Each run extracts at most `extract_batch_limit` new documents.

### `int_predicate_citations`
Grain: extraction key + `citation_seq`. One row per extracted item.

| Column | Notes |
|---|---|
| `role` | `predicate` or `reference` |
| `identifier_type` | `k_number`, `pma`, `de_novo`, `exempt`, `none`, `unidentified` |
| `identifier_raw`, `identifier_normalized` | as returned, and uppercase without spaces |
| `device_name`, `manufacturer` | as written in the document |

### `int_name_match_candidates`
Grain: citation key + `candidate_k_number`.
For predicates cited by name only: openFDA records in the same review panel,
cleared on or before the citing device, sharing at least one name word.
`match_score` is the Jaccard similarity of the word bags (device name plus
company; the citing device's applicant when no company is cited), and
`candidate_rank` orders the candidates.

### `int_name_resolution`
Grain: same as `int_predicate_citations`, name-only predicates only.
Best and second-best score, `margin`, the top 3 candidates kept for review, and
`match_status`: `matched` (score at least `name_match_min_score` and ahead of
the next candidate by `name_match_min_margin`), `ambiguous`, `no_match` or
`no_candidate`. Thresholds were calibrated on the manual review.

### `int_predicate_resolution`
Grain: same as `int_predicate_citations`.
Adds `resolved_k_number`, `resolution_method` (`identifier` or `name_match`),
`name_match_score`, the subject and predicate decision dates, and
`resolution_status` ([0004](decisions/0004-citation-model-and-resolution.md)):
`resolved`, `repaired`, `resolved_by_name`, `malformed`, `not_found`,
`date_violation`, `self_citation`, `exempt`, `name_only`, `unidentified`,
`other_pathway`.

### `int_extraction_recall_gaps`
Grain: `k_number`, `content_sha256`, `parser_version`, `candidate_k_number`.
K-numbers found by regex in `doc_text` that the model did not extract in any
role, minus the document's own number ([0003](decisions/0003-llm-extraction-regex-as-check.md)).
Candidates to review, not misses by themselves.

## Marts (dbt)

### `fct_predicate_edge`
Grain: one row per (`subject_k_number`, `predicate_k_number`), accepted prompt version.
Only `resolved`, `repaired` and `resolved_by_name` citations.

| Column | Notes |
|---|---|
| `subject_k_number`, `predicate_k_number` | |
| `subject_decision_date`, `predicate_decision_date`, `predicate_age_days` | |
| `cited_device_names` | array; one K-number can cover several listed devices |
| `resolution_method` | `identifier` if any citation of the pair had a K-number, otherwise `name_match` |
| `name_match_score`, `was_repaired`, `prompt_version` | |

### `mart_extraction_quality`
Long format: one row per metric (`metric_group`, `metric`, `numerator`,
`denominator`, `rate`, `description`). Groups: coverage, resolution, graph and
measured quality. Measured quality joins the review seeds to the current
outputs, so a review only counts while it still matches the data. Feeds the
README numbers and the dashboard.

## Seeds

- `recall_gap_review`: one row per reviewed recall gap, with `category`
  (`real_miss`, `compatible_device`, `product_family`, `co_submission`,
  `ocr_artifact`), `is_real_miss` and a note.
- `name_match_review`: one row per reviewed name match, with `verdict`
  (`correct`, `plausible`, `wrong`) and a note.

## Tests

| Test | Where | Severity |
|---|---|---|
| `unique` / `not_null` on every grain | all models and seeds | error |
| `accepted_values` for `identifier_type`, `role`, `resolution_status`, `resolution_method`, `match_status`, review categories | citations, resolution, seeds | error |
| `relationships` to `stg_openfda__submissions` (the predicate exists) | `fct_predicate_edge`, resolution, candidates, seeds | error |
| Generic `predicate_precedes_subject` | `fct_predicate_edge` | error |
| Generic `columns_differ` (no self-citation) | `fct_predicate_edge` | error |
| Generic `matches_pattern` (`^K[0-9]{6}$`) | `fct_predicate_edge` | error |
| `assert_no_parse_errors`, `assert_no_extraction_errors` | AI models | warn |
| `assert_recall_gaps_reviewed`, `assert_name_matches_reviewed` | review coverage | warn |

Unit test on `int_predicate_resolution`: one case per status, including the
repair of a 7-digit typo (`K9903690` gives `K990369`, accepted only because that
number exists and predates the subject) and a confident against an ambiguous
name match.

## Planned, not built yet

- `fct_predicate_citation`: every citation of the accepted prompt version, whatever its status. Today `int_predicate_resolution` plays this role.
- `dim_device`: one row per K-number with PDF and parse status.
- Predicate chain depth across generations (needs a larger sample).
- `mart_eval_metrics`: precision and recall per field and era against a hand-labeled seed ([0006](decisions/0006-hand-labeled-evaluation-set.md)).