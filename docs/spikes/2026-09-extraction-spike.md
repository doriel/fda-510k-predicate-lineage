# Extraction spike (September 2026)

Goal: find out what Databricks AI functions actually return on real 510(k)
summary PDFs before designing the data model.

SQL used: [`scripts/spike/`](../../scripts/spike/).

## Data access

The feasibility script ([`scripts/fda_510k_check.py`](../../scripts/fda_510k_check.py))
sampled 25 openFDA records per era and downloaded the summary PDFs.

| Era | Downloaded | No text layer (scan) | Clean text layer |
|---|---|---|---|
| 1996 to 2001 | 18/25 | 18 | 0 |
| 2002 to 2009 | 24/25 | 1 | 23 |
| 2010 to 2016 | 24/25 | 2 | 22 |
| 2017 to 2026 | 25/25 | 0 | 25 |

- URL rule: `https://www.accessdata.fda.gov/cdrh_docs/pdf{yy}/K{number}.pdf`,
  where `yy` comes from the K-number, not the decision date. K00 and K01 use
  `/pdf/` when they exist; several returned 404.
- Almost all scanned documents are from the 1990s, so that era stays in scope.

## Parsing

`ai_parse_document` on 91 PDFs:

- 0 errors, including 1990s faxes and handwritten annotations.
- Comparison tables come back as HTML tables, even from faxed pages.
- Noise to ignore: fax headers, FDA clearance letters, signatures.
- Runs on a serverless SQL warehouse ([ADR 0002](../decisions/0002-parse-in-dbt-on-sql-warehouse.md)).

## Extraction

Six hard cases, two prompt versions, same model endpoint.

| Document | Why it is hard | Prompt v1 | Prompt v2 |
|---|---|---|---|
| K960395 | 1996 fax; predicates never named | 0 items | 2 `unidentified` ✅ |
| K123598 | ~100 predicates in a list | almost none | 109 items, 102 distinct ✅ |
| K121819 | Handwriting OCR creates "K151819"; one Class I predicate | 5 ✅ | 5, Mepitac as `exempt` ✅ |
| K031909 | OCR misreads own number as "K631909" | 1 ✅ | 1 ✅ |
| K192352 | Modern control | ✅ | 1 ✅ |
| K240267 | Modern control | ✅ | 1 ✅ |

v1 failed on K123598 because the prompt itself said long K-number lists were
references. The source PDF shows them under an explicit "Predicate Devices"
heading.

## Evaluation

K123598, model output against an independent Tesseract OCR list of pages 1 to 4:

- 7 numbers only in the model output. 5 were real numbers that Tesseract
  misread (`KO021673`, `K0O72817`, `K97293}`...). 2 were printed in the PDF
  with 7 digits (`K9903690`, `K9914850`), a typo in the source document.
- 2 numbers only in the OCR list, both artifacts of the OCR script truncating
  those 7-digit numbers.
- Result: 102 of 102 distinct identifiers match the PDF. No hallucinations,
  no misses.

Lessons: the model beat automated OCR as a reference, and source documents
contain typos that must be handled by explicit rules
([ADR 0004](../decisions/0004-citation-model-and-resolution.md),
[ADR 0006](../decisions/0006-hand-labeled-evaluation-set.md)).

## Cost and time

- Parse: about 170 seconds for 91 documents (notebook serverless).
- Extract: 1 min 43 s for 6 documents with prompt v1, 2 min 15 s with v2.
  Long predicate lists dominate output tokens and time.
- Implication: batch the full corpus, and never re-run AI steps by accident
  ([ADR 0001](../decisions/0001-ai-models-incremental-no-full-refresh.md)).

## Open questions

- Throughput and cost on the full corpus, by warehouse size.
- Whether very long documents need page-level chunking before extraction.
- Resolving PMA and De Novo predicates against other openFDA endpoints.
- Applicant name normalization ("Medtronic Inc" against "Medtronic, Inc.").
