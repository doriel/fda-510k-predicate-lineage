-- Warn when a current confident name match is not covered by the manual review
-- (seed name_match_review), for example after the thresholds or the sample change.
-- Review the new matches and add them to the seed, so the measured precision stays true.
{{ config(severity='warn') }}

select m.subject_k_number, m.cited_device_name, m.best_k_number
from {{ ref('int_name_resolution') }} as m
left anti join {{ ref('name_match_review') }} as r
    on  r.subject_k_number = m.subject_k_number
    and r.cited_device_name = m.cited_device_name
    and r.matched_k_number = m.best_k_number
where m.match_status = 'matched'
  and m.prompt_version = '{{ var("accepted_prompt_version") }}'