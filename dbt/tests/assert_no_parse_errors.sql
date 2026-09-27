-- Warn (not fail) when a document failed to parse or came back empty.
-- A few failures are expected on bad scans; they should be visible, not block the run.
{{ config(severity='warn') }}

select k_number, content_sha256, parser_version, parse_error, elements
from {{ ref('int_documents_parsed') }}
where parse_error is not null
   or coalesce(elements, 0) = 0