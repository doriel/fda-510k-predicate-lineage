{#
  Extract predicate devices from each parsed document with ai_query.

  Same protection as int_documents_parsed (ADR 0001):
  - incremental + append, never updates existing rows (ADR 0005);
  - full_refresh: false, so `--full-refresh` cannot re-run the LLM on everything;
  - a document is extracted again only for a new content hash, parser version,
    prompt version or model endpoint;
  - var('extract_batch_limit') caps documents per run.
#}
{{
    config(
        materialized='incremental',
        incremental_strategy='append',
        full_refresh=false,
        tags=['ai'],
    )
}}

{% set parser_version = var('parser_version') %}
{% set prompt_version = var('prompt_version') %}
{% set endpoint = var('extraction_endpoint') %}
{% set batch_limit = var('extract_batch_limit') | int %}

with docs as (
    select k_number, content_sha256, parser_version, doc_text
    from {{ ref('int_documents_parsed') }}
    where parser_version = '{{ parser_version }}'
      and parse_error is null
      and coalesce(elements, 0) > 0
),

to_extract as (
    select d.k_number, d.content_sha256, d.parser_version, d.doc_text
    from docs as d
    {% if is_incremental() %}
    left anti join {{ this }} as t
        on  t.k_number = d.k_number
        and t.content_sha256 = d.content_sha256
        and t.parser_version = d.parser_version
        and t.prompt_version = '{{ prompt_version }}'
        and t.model_endpoint = '{{ endpoint }}'
    {% endif %}
    order by d.k_number
    {% if batch_limit >= 0 %}
    limit {{ batch_limit }}
    {% endif %}
),

extracted as (
    select
        k_number,
        content_sha256,
        parser_version,
        ai_query(
            '{{ endpoint }}',
            {{ predicate_extraction_prompt('k_number', 'doc_text') }},
            responseFormat => {{ predicate_extraction_response_format() }},
            modelParameters => named_struct('max_tokens', 16000, 'temperature', 0.0),
            failOnError => false
        ) as extraction
    from to_extract
),

parsed as (
    select
        k_number,
        content_sha256,
        parser_version,
        try_parse_json(extraction.result) as result,
        extraction.errorMessage           as error_message
    from extracted
)

select
    k_number,
    content_sha256,
    parser_version,
    '{{ prompt_version }}'                        as prompt_version,
    '{{ endpoint }}'                              as model_endpoint,
    result,
    error_message,
    result:subject_device_name::string            as subject_device_name,
    result:applicant::string                      as applicant,
    result:predicates_declared::int               as predicates_declared,
    size(result:predicates::array<variant>)       as items_extracted,
    result:extraction_notes::string               as extraction_notes,
    current_timestamp()                           as extracted_at
from parsed