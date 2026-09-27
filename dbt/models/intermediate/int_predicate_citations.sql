-- One row per predicate or reference device extracted from a document.
-- Plain table: rebuilt from stored LLM output, so it is cheap and never calls the AI.
-- Identifiers are kept exactly as extracted; validation and repair happen in the
-- resolution step (ADR 0004).

with extractions as (
    select k_number, content_sha256, parser_version, prompt_version, model_endpoint, result
    from {{ ref('int_predicate_extractions') }}
    where result is not null
),

items as (
    select
        e.k_number,
        e.content_sha256,
        e.parser_version,
        e.prompt_version,
        e.model_endpoint,
        p.pos + 1 as citation_seq,
        p.value   as item
    from extractions as e,
    lateral variant_explode(e.result:predicates) as p
),

typed as (
    select
        k_number                                                  as subject_k_number,
        content_sha256,
        parser_version,
        prompt_version,
        model_endpoint,
        citation_seq,
        item:role::string                                         as role,
        item:identifier_type::string                              as identifier_type,
        item:identifier::string                                   as identifier_raw,
        upper(regexp_replace(item:identifier::string, '\\s', '')) as identifier_normalized,
        item:device_name::string                                  as device_name,
        item:manufacturer::string                                 as manufacturer,
        item:ocr_suspect::boolean                                 as ocr_suspect,
        item:evidence::string                                     as evidence
    from items
)

select
    *,
    -- Format check per identifier type; null when the type carries no identifier.
    case identifier_type
        when 'k_number' then identifier_normalized rlike '^K[0-9]{6}$'
        when 'pma'      then identifier_normalized rlike '^P[0-9]{6}$'
        when 'de_novo'  then identifier_normalized rlike '^DEN[0-9]{6}$'
    end as is_well_formed
from typed