# Data model

Physical model for the pipeline, based on the
[extraction spike](spikes/2026-09-extraction-spike.md) and the
[decision records](decisions/README.md).

Catalog and schema are variables (bundle and dbt profile), so the project runs
in any workspace. Table names below omit them.

## Questions the gold layer answers

1. Which devices are cited most often as predicates?
2. How deep do predicate chains go?
3. Do new devices cite predicates that were later recalled?
4. How old are predicates when they are cited, by product code and panel?
5. How accurate is the extraction, by field, era, document quality and prompt version?

## Flow

```
openFDA API ──► bronze_openfda_510k ──► stg_openfda__submissions ──► dim_device
                                                     │
PDF download ─► Volume ─► bronze_pdf_files           │
                               │                     │
                               ▼                     ▼
                     int_documents_parsed     int_predicate_resolution ──► fct_predicate_edge
                               │                     ▲                 └─► fct_predicate_citation
                               ▼                     │
                   int_predicate_extractions ─► int_predicate_citations
                               │
                               └──► int_regex_candidates ──► mart_extraction_quality
                                                                   ▲
                                        seed: eval_labels ─► mart_eval_metrics
```

Python jobs own the bronze tables. dbt owns everything after that.

## Bronze (Python jobs)

### `bronze_openfda_510k`
Grain: one row per K-number per ingestion.

| Column | Type | Notes |
|---|---|---|
| `k_number` | string | |
| `raw` | variant | Full openFDA record |
| `ingested_at` | timestamp | |

### `bronze_pdf_files`
Grain: one row per PDF version (`k_number`, `content_sha256`).

| Column | Type | Notes |
|---|---|---|
| `k_number` | string | From the file name |
| `path` | string | Volume path |
| `content` | binary | |
| `content_sha256` | string | Changes only if FDA replaces the file |
| `length` | bigint | |
| `source_url` | string | accessdata.fda.gov URL |
| `download_status` | string | `ok`, `http_404`, ... Missing PDFs are recorded, not dropped |
| `ingested_at` | timestamp | |

## Staging and intermediate (dbt)

### `stg_openfda__submissions`
Grain: one row per K-number (latest ingestion). Typed openFDA fields:
`decision_date`, `date_received`, `applicant`, `device_name`, `product_code`,
`device_class`, `review_panel`, `decision_code`, `clearance_type`,
`statement_or_summary`.

### `int_documents_parsed`
Incremental, `full_refresh: false` ([0001](decisions/0001-ai-models-incremental-no-full-refresh.md)).
Grain: `k_number`, `content_sha256`, `parser_version`.

| Column | Notes |
|---|---|
| `parsed` | variant, raw `ai_parse_document` output |
| `parse_error` | null when fine |
| `pages`, `elements` | counts |
| `doc_text` | concatenated element content, input to extraction |
| `parsed_at` | |

### `int_predicate_extractions`
Incremental, `full_refresh: false`.
Grain: `k_number`, `content_sha256`, `prompt_version`, `model_endpoint`.

| Column | Notes |
|---|---|
| `result` | variant, raw JSON returned by `ai_query` |
| `error_message` | |
| `subject_device_name`, `applicant` | as extracted, compared with openFDA later |
| `predicates_declared` | model's own count, a warning signal only |
| `extraction_notes` | |
| `extracted_at` | |

### `int_predicate_citations`
Grain: one row per extracted item: extraction key + `citation_seq`.

| Column | Notes |
|---|---|
| `role` | `predicate` or `reference` |
| `identifier_type` | `k_number`, `pma`, `de_novo`, `exempt`, `none`, `unidentified` |
| `identifier_raw` | as returned |
| `identifier_normalized` | uppercase, no spaces |
| `is_well_formed` | matches the pattern for its type (`^K\d{6}$` for K-numbers) |
| `device_name`, `manufacturer` | |
| `ocr_suspect` | model flag |
| `evidence` | short excerpt, null for long lists |

### `int_predicate_resolution`
Grain: same as `int_predicate_citations`.
Adds `resolved_k_number`, `repair_rule` (null unless repaired) and
`resolution_status` (see [0004](decisions/0004-citation-model-and-resolution.md)),
plus `predicate_decision_date` from openFDA.

### `int_regex_candidates`
Grain: `k_number`, `content_sha256`, `candidate_k_number`.
Every K-number found by regex in `doc_text`, minus the document's own number.
Candidates not extracted by the LLM feed the recall check.

## Marts (dbt)

### `dim_device`
Grain: one row per K-number, from `stg_openfda__submissions`. Includes
whether a summary PDF exists and its parse status.

### `fct_predicate_citation`
Grain: one row per citation for the accepted prompt version
(`var('accepted_prompt_version')`). Every citation, whatever its
`resolution_status`, so nothing disappears from view.

### `fct_predicate_edge`
Grain: one row per (`subject_k_number`, `predicate_k_number`).
Only `resolved` and `repaired` citations.

| Column | Notes |
|---|---|
| `subject_k_number`, `predicate_k_number` | |
| `subject_decision_date`, `predicate_decision_date` | |
| `predicate_age_days` | subject minus predicate decision date |
| `cited_device_names` | array; one K-number can cover several listed devices |
| `was_repaired` | |
| `prompt_version` | |

### `mart_extraction_quality`
Grain: one row per document and prompt version. Counts by resolution status,
declared against extracted, regex candidates not extracted, parse errors,
era and document quality.

### `mart_eval_metrics`
Grain: prompt version, field, era. Precision and recall against the
hand-labeled seed `eval_labels` ([0006](decisions/0006-hand-labeled-evaluation-set.md)).

## Tests

| Test | Model | Severity |
|---|---|---|
| `unique` / `not_null` on each grain | all | error |
| `accepted_values` for `identifier_type`, `resolution_status`, `role` | citations, resolution | error |
| Custom: `predicate_exists_in_openfda` | `fct_predicate_edge` | error |
| Custom: `predicate_precedes_subject` | `fct_predicate_edge` | error |
| No self-citation (`subject_k_number != predicate_k_number`) | `fct_predicate_edge` | error |
| `predicate_k_number` matches `^K\d{6}$` | `fct_predicate_edge` | error |
| Declared count differs from extracted | `int_predicate_extractions` | warn |
| Regex candidates not extracted | `int_regex_candidates` | warn |
| Share of `malformed` or `not_found` above a threshold | `mart_extraction_quality` | warn |

Unit tests (dbt unit tests): identifier normalization, repair rules
(`K9903690` gives `K990369`, accepted only if it exists and predates the
subject), and resolution status logic on fixed inputs.
