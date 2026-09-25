# 0004. Citations carry an identifier type and a resolution status, validated in dbt

- Status: Accepted
- Date: 2026-09-25

## Context

A predicate citation is not always a clean foreign key to another 510(k):

- It can be a K-number, a PMA number, a De Novo number, a 510(k)-exempt device,
  a named device with no number, or a predicate the document never identifies.
- The number itself can be wrong in the source. K123598 prints
  "K9903690" and "K9914850", seven digits, where a K-number has six.
- A number can be well formed but impossible, for example a predicate cleared
  after the device that cites it.

## Decision

Each extracted citation keeps:

- `identifier_type`: `k_number`, `pma`, `de_novo`, `exempt`, `none`, `unidentified`.
- `identifier_raw`: exactly as the model returned it.

dbt then resolves each citation and sets `resolution_status`:

| Status | Meaning |
|---|---|
| `resolved` | Well-formed K-number found in openFDA, cleared before the subject device |
| `repaired` | Malformed number with exactly one repair candidate that passes both checks above |
| `malformed` | Does not match `^K\d{6}$` and no single repair candidate passes |
| `not_found` | Well-formed but not in openFDA |
| `date_violation` | Found in openFDA but cleared after the subject device |
| `exempt` | 510(k) exempt, no number expected |
| `name_only` | Named device without an identifier |
| `unidentified` | Predicate exists but is never named |
| `other_pathway` | PMA or De Novo number (resolution against other openFDA endpoints is future work) |

Repair rules are explicit, few and unit-tested. The first one: a
7-digit number ending in `0` produces the candidate without that `0`
(`K9903690` gives `K990369`). The repair is accepted only if the candidate
passes the existence and date checks.

## Consequences

- The lineage graph (`fct_predicate_edge`) contains only `resolved` and
  `repaired` citations. Everything else stays visible in the citation table
  and the quality metrics, never silently dropped.
- The date-order rule is enforced twice: as a status during resolution and as
  a dbt test on the edge table.
- The grain of the edge table is one row per (subject, predicate K-number).
  Several listed devices can share one K-number (K921400 covers two devices in
  K123598), so device names are kept as an attribute.

## Evidence

- K9903690 and K9914850 printed on page 1 of K123598.
- K121819 predicate table: Mepitac listed as "Class I".
- K960395: "Predicated device 1" and "2", never named.
