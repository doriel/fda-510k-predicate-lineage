-- Warn when the model's own predicate count differs from what it extracted.
-- A warning, not an error: LLMs miscount long lists (K123598 said 113 for 109
-- correct items in the spike), so this flags documents to review (ADR 0003).
{{ config(severity='warn') }}

with predicates as (
    select subject_k_number, prompt_version, model_endpoint, count(*) as extracted_predicates
    from {{ ref('int_predicate_citations') }}
    where role = 'predicate'
    group by all
)

select
    e.k_number,
    e.prompt_version,
    e.predicates_declared,
    coalesce(p.extracted_predicates, 0) as extracted_predicates
from {{ ref('int_predicate_extractions') }} as e
left join predicates as p
    on  p.subject_k_number = e.k_number
    and p.prompt_version = e.prompt_version
    and p.model_endpoint = e.model_endpoint
where e.result is not null
  and e.predicates_declared != coalesce(p.extracted_predicates, 0)