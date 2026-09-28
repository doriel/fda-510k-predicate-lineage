{#
  Candidate openFDA records for predicates cited by name only
  (identifier_type = 'none'). Reads from int_predicate_citations, not from
  int_predicate_resolution, because the resolution uses these results.

  Blocking rules, so only plausible candidates are scored:
  - same review panel as the subject device;
  - cleared on or before the subject device (a predicate must already exist);
  - not the subject device itself;
  - shares at least one meaningful word in the device name.

  Score: Jaccard similarity between two bags of words, device name plus company:
  - cited side: device name + cited manufacturer, or the SUBJECT's applicant when
    no manufacturer is cited (most name-only predicates are the same company's
    earlier products, and without this a different company's product with a
    near-identical generic name can win);
  - candidate side: openFDA device name + applicant.
  Comparing one combined bag means a company name counts the same whether it
  appears in the device name ("ZIMMER ANATOMIC HIP") or in the company field.

  Deterministic and explainable on purpose; no LLM in this step.
#}

{% set accepted = var('accepted_prompt_version') %}

with name_only as (
    select
        c.subject_k_number,
        c.content_sha256,
        c.parser_version,
        c.prompt_version,
        c.model_endpoint,
        c.citation_seq,
        c.device_name,
        c.manufacturer
    from {{ ref('int_predicate_citations') }} as c
    where c.identifier_type = 'none'
      and c.role = 'predicate'
      and c.prompt_version = '{{ accepted }}'
      and c.model_endpoint = '{{ var("extraction_endpoint") }}'
),

citations as (
    select
        n.*,
        s.decision_date                                               as subject_decision_date,
        s.review_panel_code                                           as subject_panel,
        coalesce(n.manufacturer, s.applicant)                         as company_used,
        if(n.manufacturer is null, 'subject_applicant', 'cited')      as company_source,
        {{ name_tokens('n.device_name') }}                            as name_words,
        array_distinct(concat(
            {{ name_tokens('n.device_name') }},
            {{ name_tokens('coalesce(n.manufacturer, s.applicant)') }}
        ))                                                            as all_words
    from name_only as n
    left join {{ ref('stg_openfda__submissions') }} as s
        on s.k_number = n.subject_k_number
),

openfda as (
    select
        k_number,
        device_name,
        applicant,
        decision_date,
        review_panel_code,
        product_code,
        {{ name_tokens('device_name') }}                              as name_words,
        array_distinct(concat(
            {{ name_tokens('device_name') }},
            {{ name_tokens('applicant') }}
        ))                                                            as all_words
    from {{ ref('stg_openfda__submissions') }}
    where device_name is not null
      and decision_date is not null
),

-- Blocking: one row per (citation, name word) and (openFDA record, name word),
-- joined on the word. Company words are not used for blocking, or every
-- product of the same company would become a candidate.
citation_words as (
    select c.*, w as word
    from citations as c
    lateral view explode(c.name_words) as w
),

openfda_words as (
    select o.*, w as word
    from openfda as o
    lateral view explode(o.name_words) as w
),

pairs as (
    select distinct
        c.subject_k_number, c.content_sha256, c.parser_version, c.prompt_version, c.model_endpoint, c.citation_seq,
        o.k_number
    from citation_words as c
    inner join openfda_words as o
        on  o.word = c.word
        and o.review_panel_code = c.subject_panel
        and o.decision_date <= c.subject_decision_date
        and o.k_number != c.subject_k_number
),

scored as (
    select
        c.subject_k_number,
        c.content_sha256,
        c.parser_version,
        c.prompt_version,
        c.model_endpoint,
        c.citation_seq,
        c.device_name                                        as cited_device_name,
        c.manufacturer                                       as cited_manufacturer,
        c.company_used,
        c.company_source,
        o.k_number                                           as candidate_k_number,
        o.device_name                                        as candidate_device_name,
        o.applicant                                          as candidate_applicant,
        o.decision_date                                      as candidate_decision_date,
        o.product_code                                       as candidate_product_code,
        round({{ jaccard('c.name_words', 'o.name_words') }}, 3) as name_score,
        round({{ jaccard('c.all_words', 'o.all_words') }}, 3)   as match_score
    from pairs as p
    inner join citations as c
        on  c.subject_k_number = p.subject_k_number
        and c.content_sha256 = p.content_sha256
        and c.parser_version = p.parser_version
        and c.prompt_version = p.prompt_version
        and c.model_endpoint = p.model_endpoint
        and c.citation_seq = p.citation_seq
    inner join openfda as o
        on o.k_number = p.k_number
)

select
    *,
    row_number() over (
        partition by subject_k_number, content_sha256, parser_version, prompt_version, model_endpoint, citation_seq
        order by match_score desc, name_score desc, candidate_decision_date desc, candidate_k_number
    ) as candidate_rank
from scored