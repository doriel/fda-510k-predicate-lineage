{#
  One row per predicate cited by name only, with the matching decision.

  match_status:
    matched       best score >= name_match_min_score AND ahead of the second
                  candidate by at least name_match_min_margin
    ambiguous     best score passes the threshold but another candidate is too close
                  (common when one product has several clearances with the same name)
    no_match      candidates exist but none passes the threshold
    no_candidate  no openFDA record shares a word, panel and date window

  Thresholds are vars, calibrated on a manual review (seed name_match_review).
  Matched citations become resolved_by_name in int_predicate_resolution.
#}

{% set min_score = var('name_match_min_score') %}
{% set min_margin = var('name_match_min_margin') %}
{% set accepted = var('accepted_prompt_version') %}

with name_only as (
    select subject_k_number, content_sha256, parser_version, prompt_version, model_endpoint,
           citation_seq, device_name, manufacturer
    from {{ ref('int_predicate_citations') }}
    where identifier_type = 'none'
      and role = 'predicate'
      and prompt_version = '{{ accepted }}'
      and model_endpoint = '{{ var("extraction_endpoint") }}'
),

ranked as (
    select
        subject_k_number, content_sha256, parser_version, prompt_version, model_endpoint, citation_seq,
        max(if(candidate_rank = 1, candidate_k_number, null))  as best_k_number,
        max(if(candidate_rank = 1, match_score, null))         as best_score,
        max(if(candidate_rank = 2, match_score, null))         as second_score,
        count(*)                                               as candidates_scored,
        -- Top 3 candidates, kept for review.
        array_sort(
            collect_list(
                if(candidate_rank <= 3,
                   named_struct(
                       'rank', candidate_rank,
                       'k_number', candidate_k_number,
                       'device_name', candidate_device_name,
                       'applicant', candidate_applicant,
                       'decision_date', candidate_decision_date,
                       'score', match_score
                   ),
                   null)
            )
        )                                                      as top_candidates
    from {{ ref('int_name_match_candidates') }}
    group by all
)

select
    n.subject_k_number,
    n.content_sha256,
    n.parser_version,
    n.prompt_version,
    n.model_endpoint,
    n.citation_seq,
    n.device_name                                  as cited_device_name,
    n.manufacturer                                 as cited_manufacturer,
    r.best_k_number,
    r.best_score,
    r.second_score,
    round(r.best_score - coalesce(r.second_score, 0), 3) as margin,
    coalesce(r.candidates_scored, 0)               as candidates_scored,
    r.top_candidates,
    case
        when r.best_score is null                                                   then 'no_candidate'
        when r.best_score >= {{ min_score }}
             and r.best_score - coalesce(r.second_score, 0) >= {{ min_margin }}     then 'matched'
        when r.best_score >= {{ min_score }}                                        then 'ambiguous'
        else 'no_match'
    end                                            as match_status
from name_only as n
left join ranked as r
    on  r.subject_k_number = n.subject_k_number
    and r.content_sha256 = n.content_sha256
    and r.parser_version = n.parser_version
    and r.prompt_version = n.prompt_version
    and r.model_endpoint = n.model_endpoint
    and r.citation_seq = n.citation_seq