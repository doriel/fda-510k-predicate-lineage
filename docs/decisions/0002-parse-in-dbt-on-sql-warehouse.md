# 0002. Document parsing runs in dbt on a SQL warehouse

- Status: Accepted
- Date: 2026-09-25

## Context

The pipeline is split between Python jobs and dbt. It was open whether
`ai_parse_document` could run on a SQL warehouse (which dbt uses) or only on
notebook or job compute. If it could not, the parse step would have to live
in Python.

## Decision

- Python jobs own what dbt is weak at: calling the openFDA API, downloading
  PDFs into a Unity Catalog Volume, and loading them as binary into a bronze
  table.
- dbt owns everything from parsing onward: parse, extraction, resolution,
  marts, tests and evaluation.

## Consequences

- The AI steps get dbt lineage, documentation and tests like any other model.
- The parse model must follow [0001](0001-ai-models-incremental-no-full-refresh.md).
- A single call took about 22 seconds on a 2XS serverless warehouse, against
  about 2 seconds per document in a notebook batch. Throughput on the full
  corpus must be measured before choosing warehouse size and batch size.

## Evidence

- `SELECT ai_parse_document(content) IS NOT NULL` returned `true` on a serverless
  SQL warehouse for K960395 ([`scripts/spike/01_parse.sql`](../../scripts/spike/01_parse.sql), query 4).
