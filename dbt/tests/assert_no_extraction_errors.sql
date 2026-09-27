-- Warn when ai_query failed for a document or returned something that is not valid JSON.
{{ config(severity='warn') }}

select k_number, prompt_version, model_endpoint, error_message
from {{ ref('int_predicate_extractions') }}
where error_message is not null
   or result is null