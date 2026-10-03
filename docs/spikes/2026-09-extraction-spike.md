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

## Open questions, and what happened to them

Written during the spike; the answers come from running the pipeline daily on
a growing sample (170 documents by early October 2026).

- **Throughput and cost on the full corpus.** Not measured on the full corpus.
  The daily run (up to 15 new PDFs) takes 3 to 4 minutes for `dbt build`, most
  of it in parsing and extraction. Batch limits per run keep the AI cost bounded.
- **Page-level chunking for long documents.** Not needed so far. The longest
  documents, such as the 28-page K123598, are extracted whole.
- **PMA and De Novo predicates.** Still open. They get the status
  `other_pathway` and stay out of the graph (1 citation so far).
- **Applicant name normalization.** Solved as part of name matching: device
  name and company are compared as bags of words, after removing punctuation,
  trademark signs and plurals.

## After the spike

Findings from the reviews of the running pipeline, recorded in the
[decision records](../decisions/README.md) and the review seeds:

- **Predicates cited by name only.** About 10% of predicate citations have no
  K-number, mostly in 1990s and 2000s summaries. A conservative word-similarity
  match resolves them when one openFDA record is clearly ahead of the others;
  23 matches reviewed, none wrong ([ADR 0004](../decisions/0004-citation-model-and-resolution.md), amended).
- **The recall check finds more noise than misses.** 77 K-numbers in the text
  were not extracted. Only 1 was a real miss (K223828, a device named in the
  same substantial equivalence sentence as one the model extracted as a
  reference). The rest:
  - OCR misreading the document's own number in a header or form, sometimes
    into a real but unrelated device (a dosimetry software, a histology product);
  - compatible devices listed in the indications for use;
  - earlier products of the same family;
  - devices cleared in the same FDA letter.
- **The model's own count of predicates is not reliable.** A test comparing it
  with the extracted list gave only false warnings and was removed.
- **Prompt v2 holds.** The daily runs use prompt v2 unchanged. The one real
  miss is the input for the next prompt version.