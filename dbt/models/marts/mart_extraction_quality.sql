-- Pipeline quality in one place, one row per metric (long format), for the
-- accepted prompt version. Feeds the README numbers and the dashboard.
--
-- Groups:
--   coverage          how many documents made it through each AI step
--   resolution        predicate citations by resolution status
--   graph             size and shape of the lineage graph
--   measured_quality  results of the manual reviews (seeds recall_gap_review
--                     and name_match_review), joined to the current outputs so
--                     only reviews that still match the data are counted
--
-- rate = numerator / denominator when a denominator applies.

{% set accepted = var('accepted_prompt_version') %}
{% set parser_version = var('parser_version') %}
{% set endpoint = var('extraction_endpoint') %}

with pdfs as (
    select * from {{ ref('stg_pdf_files') }}
),

parsed as (
    select * from {{ ref('int_documents_parsed') }}
    where parser_version = '{{ parser_version }}'
),

extracted as (
    select * from {{ ref('int_predicate_extractions') }}
    where prompt_version = '{{ accepted }}'
      and parser_version = '{{ parser_version }}'
      and model_endpoint = '{{ endpoint }}'
),

citations as (
    select * from {{ ref('int_predicate_resolution') }}
    where prompt_version = '{{ accepted }}'
      and parser_version = '{{ parser_version }}'
      and model_endpoint = '{{ endpoint }}'
      and role = 'predicate'
),

edges as (
    select * from {{ ref('fct_predicate_edge') }}
),

gaps as (
    select * from {{ ref('int_extraction_recall_gaps') }}
),

gap_review as (
    select * from {{ ref('recall_gap_review') }}
),

-- Current recall gaps with their review, if any.
gaps_reviewed as (
    select g.k_number, g.candidate_k_number, r.category, r.is_real_miss
    from gaps as g
    left join gap_review as r
        on  r.document_k_number = g.k_number
        and r.candidate_k_number = g.candidate_k_number
),

-- Current confident name matches with their review, if any. A review only counts
-- if it is for the same matched K-number (thresholds may change the match).
name_matches_reviewed as (
    select m.subject_k_number, m.cited_device_name, m.best_k_number, r.verdict
    from {{ ref('int_name_resolution') }} as m
    left join {{ ref('name_match_review') }} as r
        on  r.subject_k_number = m.subject_k_number
        and r.cited_device_name = m.cited_device_name
        and r.matched_k_number = m.best_k_number
    where m.match_status = 'matched'
      and m.prompt_version = '{{ accepted }}'
),

metrics as (

    -- coverage ---------------------------------------------------------------
    select 'coverage' as metric_group, 'pdfs_downloaded' as metric,
           count_if(download_status = 'ok') as numerator, count(*) as denominator,
           'Summary PDFs downloaded out of download attempts (the rest are not on the FDA site)' as description
    from pdfs

    union all
    select 'coverage', 'documents_parsed',
           count_if(parse_error is null and coalesce(elements, 0) > 0), count(*),
           'Downloaded PDFs parsed into text by ai_parse_document'
    from parsed

    union all
    select 'coverage', 'documents_extracted',
           count_if(error_message is null and result is not null), count(*),
           'Parsed documents extracted without error by ai_query'
    from extracted

    -- resolution -------------------------------------------------------------
    union all
    select 'resolution', concat('citations_', resolution_status),
           count(*), (select count(*) from citations),
           'Predicate citations with this resolution status'
    from citations
    group by resolution_status

    union all
    select 'resolution', 'citations_in_graph',
           count_if(resolution_status in ('resolved', 'repaired', 'resolved_by_name')), count(*),
           'Predicate citations resolved to an openFDA record (by identifier or name)'
    from citations

    -- graph ------------------------------------------------------------------
    union all
    select 'graph', 'edges', count(*), null,
           'Lineage edges (subject device cites predicate device)'
    from edges

    union all
    select 'graph', 'edges_by_identifier', count_if(resolution_method = 'identifier'), count(*),
           'Edges resolved from a K-number in the document'
    from edges

    union all
    select 'graph', 'edges_by_name_match', count_if(resolution_method = 'name_match'), count(*),
           'Edges resolved only by name matching (less certain)'
    from edges

    union all
    select 'graph', 'devices_with_predicates',
           count(distinct subject_k_number),
           (select count(*) from extracted where result is not null),
           'Extracted devices with at least one predicate in the graph'
    from edges

    union all
    select 'graph', 'distinct_predicates', count(distinct predicate_k_number), null,
           'Distinct predicate devices cited'
    from edges

    union all
    select 'graph', 'median_predicate_age_days', percentile(predicate_age_days, 0.5), null,
           'Median days between a predicate clearance and the clearance of the device citing it'
    from edges

    -- measured quality -------------------------------------------------------
    union all
    select 'measured_quality', 'recall_gaps_reviewed',
           count(category), count(*),
           'Current recall gaps (regex found, LLM did not extract) covered by the manual review'
    from gaps_reviewed

    union all
    select 'measured_quality', 'recall_gaps_real_misses',
           count_if(is_real_miss), count(category),
           'Reviewed recall gaps that were real extraction misses'
    from gaps_reviewed

    union all
    select 'measured_quality', 'name_matches_reviewed',
           count(verdict), count(*),
           'Current confident name matches covered by the manual review'
    from name_matches_reviewed

    union all
    select 'measured_quality', 'name_matches_correct',
           count_if(verdict = 'correct'), count(verdict),
           'Reviewed name matches that are clearly the cited device'
    from name_matches_reviewed

    union all
    select 'measured_quality', 'name_matches_correct_or_plausible',
           count_if(verdict in ('correct', 'plausible')), count(verdict),
           'Reviewed name matches that are correct or plausible'
    from name_matches_reviewed

    union all
    select 'measured_quality', 'name_matches_wrong',
           count_if(verdict = 'wrong'), count(verdict),
           'Reviewed name matches that point to the wrong device'
    from name_matches_reviewed
)

select
    metric_group,
    metric,
    cast(numerator as double)                                   as numerator,
    cast(denominator as double)                                 as denominator,
    round(cast(numerator as double) / nullif(denominator, 0), 3) as rate,
    description,
    '{{ accepted }}'                                            as prompt_version,
    current_timestamp()                                         as computed_at
from metrics