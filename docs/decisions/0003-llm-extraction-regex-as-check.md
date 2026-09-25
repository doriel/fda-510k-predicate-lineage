# 0003. Predicates are extracted by an LLM; regex is only a recall check

- Status: Accepted
- Date: 2026-09-25

## Context

The first idea was to find predicate K-numbers with a regular expression on the
parsed text. In the spike, 78 of 91 documents mentioned at least one other
K-number, but regex could not tell predicates from noise:

- **Predicates without a number.** K121819 cites Mepitac as "Class I" (510(k)
  exempt). K960395 compares against "Predicated device 1" and "2" and never
  names them.
- **Numbers that are not predicates, or not real.** Handwriting misread by OCR
  produced "K151819" (the document's own number, K121819). OCR turned K031909
  into "K631909".
- **Long lists.** K123598 lists about 100 real predicates, which regex finds,
  but regex also picks up page headers and letter references.

## Decision

- Predicates are extracted with `ai_query` and a strict JSON schema: role,
  identifier type, identifier, device name, manufacturer, OCR flag, short
  evidence.
- The prompt copies identifiers as written and never corrects them.
  Correction happens in dbt, where it is deterministic and testable
  (see [0004](0004-citation-model-and-resolution.md)).
- Regex is kept as an independent **recall check**: every K-number found by
  regex in a document, minus the document's own number, that the LLM did not
  extract is listed for review.

## Consequences

- Extraction costs one LLM call per document.
- Recall problems surface automatically instead of silently.
- The model's self-reported count (`predicates_declared`) is only a warning:
  it matched on 5 of 6 documents but said 113 for K123598, where 109 items
  were extracted and all 102 distinct numbers were correct.

## Evidence

- Prompt v1 found 10 items across 6 documents; prompt v2 found 119, with all
  102 distinct identifiers in K123598 matching the PDF
  ([spike write-up](../spikes/2026-09-extraction-spike.md#extraction)).
