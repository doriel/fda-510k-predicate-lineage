# 0006. Accuracy is measured against a hand-labeled evaluation set

- Status: Accepted
- Date: 2026-09-25

## Context

Two shortcuts for "ground truth" failed during the spike:

- **Assumptions.** Before reading the PDFs, the expected answers were wrong for
  2 of 6 test documents. K123598's long list was assumed to be references (it
  is predicates), and K960395's predicates were assumed to be named (they are not).
- **Automated OCR.** A Tesseract reference list for K123598 had 5 misread
  numbers out of 97 (for example `K0O72817`), plus 2 truncated ones. The LLM
  extraction had none.

## Decision

- An evaluation set of 20 to 30 documents is labeled by hand from the PDFs,
  stratified by era (1996 to 2001 scans, 2002 to 2016, 2017 onward) and by
  difficulty (long lists, unnamed predicates, exempt devices, handwriting).
- Labels live in a dbt seed: one row per (document, predicate) with the
  expected identifier type, identifier, device name and manufacturer.
- dbt computes precision and recall per field, era and prompt version with
  anti-joins in both directions, the same pattern used in
  [`scripts/spike/04_eval_k123598_diff.sql`](../../scripts/spike/04_eval_k123598_diff.sql).
- Automated checks (regex recall, openFDA existence, date order) run on the
  whole corpus, but are reported as checks, not as accuracy.

## Consequences

- Labeling takes a few hours of manual work.
- Accuracy numbers in the README are backed by labels anyone can inspect.

## Evidence

- [Spike write-up](../spikes/2026-09-extraction-spike.md#evaluation).
