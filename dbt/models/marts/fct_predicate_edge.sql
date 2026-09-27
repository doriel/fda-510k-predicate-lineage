-- The predicate lineage graph: one row per (subject device, predicate K-number),
-- for the accepted prompt version. Only resolved and repaired predicates;
-- everything else stays visible in int_predicate_resolution (ADR 0004).
-- Several listed devices can share one K-number, so their names are kept as an array.

{% set accepted = var('accepted_prompt_version') %}

with citations as (
    select *
    from {{ ref('int_predicate_resolution') }}
    where prompt_version = '{{ accepted }}'
      and parser_version = '{{ var("parser_version") }}'
      and model_endpoint = '{{ var("extraction_endpoint") }}'
      and role = 'predicate'
      and resolution_status in ('resolved', 'repaired')
)

select
    subject_k_number,
    resolved_k_number                                                  as predicate_k_number,
    min(subject_decision_date)                                         as subject_decision_date,
    min(predicate_decision_date)                                       as predicate_decision_date,
    datediff(min(subject_decision_date), min(predicate_decision_date)) as predicate_age_days,
    array_sort(collect_set(device_name))                               as cited_device_names,
    bool_or(resolution_status = 'repaired')                            as was_repaired,
    '{{ accepted }}'                                                   as prompt_version
from citations
group by subject_k_number, resolved_k_number