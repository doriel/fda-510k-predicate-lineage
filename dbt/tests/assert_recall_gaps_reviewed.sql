-- Warn when a current recall gap is not covered by the manual review (seed
-- recall_gap_review). Happens after the sample grows or the prompt changes:
-- review the new rows and add them to the seed, so the measured recall stays true.
{{ config(severity='warn') }}

select g.k_number, g.candidate_k_number
from {{ ref('int_extraction_recall_gaps') }} as g
left anti join {{ ref('recall_gap_review') }} as r
    on  r.document_k_number = g.k_number
    and r.candidate_k_number = g.candidate_k_number