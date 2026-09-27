{#
  Parse each downloaded PDF once with ai_parse_document.

  - incremental + append: new documents add rows; existing rows are never
    updated (ADR 0005).
  - full_refresh: false: `dbt run --full-refresh` cannot rebuild this model and
    re-run the AI on every document by accident (ADR 0001).
  - A document is parsed again only if its content changes (new sha256) or
    var('parser_version') is bumped.
  - var('parse_batch_limit') caps documents per run to keep cost predictable.
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
{% set batch_limit = var('parse_batch_limit') | int %}

with pdfs as (
    select k_number, content_sha256, content
    from {{ ref('stg_pdf_files') }}
    where download_status = 'ok'
),

to_parse as (
    select p.k_number, p.content_sha256, p.content
    from pdfs as p
    {% if is_incremental() %}
    left anti join {{ this }} as t
        on  t.k_number = p.k_number
        and t.content_sha256 = p.content_sha256
        and t.parser_version = '{{ parser_version }}'
    {% endif %}
    order by p.k_number
    {% if batch_limit >= 0 %}
    limit {{ batch_limit }}
    {% endif %}
),

parsed as (
    select
        k_number,
        content_sha256,
        ai_parse_document(content) as parsed
    from to_parse
)

select
    k_number,
    content_sha256,
    '{{ parser_version }}'                                   as parser_version,
    parsed,
    parsed:error_status::string                              as parse_error,
    size(parsed:document:pages::array<variant>)              as pages,
    size(parsed:document:elements::array<variant>)           as elements,
    concat_ws(
        '\n\n',
        transform(parsed:document:elements::array<variant>, e -> e:content::string)
    )                                                        as doc_text,
    current_timestamp()                                      as parsed_at
from parsed