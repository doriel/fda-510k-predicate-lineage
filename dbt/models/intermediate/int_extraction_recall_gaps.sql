-- Recall check (ADR 0003): every K-number that regex finds in a document's text
-- but the LLM did not extract, in any role, for the accepted prompt version.
--
-- Not every row is a miss: documents also mention K-numbers that are neither
-- predicates nor references (history of prior clearances, for example).
-- This table lists candidates to review; a quality mart will report the counts.

{% set accepted = var('accepted_prompt_version') %}

with docs as (
    select k_number, content_sha256, parser_version, doc_text
    from {{ ref('int_documents_parsed') }}
    where parser_version = '{{ var("parser_version") }}'
),

regex_candidates as (
    select distinct
        k_number,
        content_sha256,
        parser_version,
        upper(regexp_replace(raw_candidate, '\\s', '')) as candidate_k_number
    from (
        select
            k_number,
            content_sha256,
            parser_version,
            -- K + optional space + 6 digits, not followed by another digit,
            -- so a 7-digit typo like K9903690 is not cut down to K990369.
            explode(regexp_extract_all(doc_text, '([Kk] ?[0-9]{6})(?![0-9])', 1)) as raw_candidate
        from docs
    )
),

extracted as (
    select distinct subject_k_number, content_sha256, parser_version, identifier_normalized
    from {{ ref('int_predicate_citations') }}
    where prompt_version = '{{ accepted }}'
      and model_endpoint = '{{ var("extraction_endpoint") }}'
      and identifier_normalized is not null
)

select
    r.k_number,
    r.content_sha256,
    r.parser_version,
    '{{ accepted }}' as prompt_version,
    r.candidate_k_number
from regex_candidates as r
left anti join extracted as e
    on  e.subject_k_number = r.k_number
    and e.content_sha256 = r.content_sha256
    and e.parser_version = r.parser_version
    and e.identifier_normalized = r.candidate_k_number
where r.candidate_k_number != r.k_number