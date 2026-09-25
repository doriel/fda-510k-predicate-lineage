# 0005. Extractions are versioned and never overwritten

- Status: Accepted
- Date: 2026-09-25

## Context

The prompt changed materially during the spike. Prompt v1 told the model that
long K-number lists were references, and it extracted almost nothing from
K123598. Prompt v2 fixed that. Without both results side by side, the
improvement could not have been measured.

## Decision

- Every parse and extraction row records `parser_version` or `prompt_version`,
  the model endpoint, and a timestamp.
- New versions add rows. Old rows are never updated or deleted.
- The accepted version for the marts is a dbt variable
  (`accepted_prompt_version`), so switching versions is a reviewed change.

## Consequences

- Prompt changes can be compared on the same documents with SQL.
- Storage grows with each version, which is negligible at this scale.
- Rolling back a prompt is a variable change, not a reprocessing job.

## Evidence

- `fda_spike_extracted` (v1) and `fda_spike_extracted_v2` (v2) compared on
  the same 6 documents: 10 items against 119.
