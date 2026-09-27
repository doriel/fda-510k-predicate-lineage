-- One row per K-number from the latest openFDA export, with typed fields.
-- This covers ALL 510(k)s, not only the PDF sample, because predicates can
-- come from any product code.

with latest_export as (
    select max(export_date) as export_date
    from {{ source('bronze', 'openfda_510k') }}
),

records as (
    select b.k_number, b.raw, b.export_date
    from {{ source('bronze', 'openfda_510k') }} as b
    inner join latest_export as l
        on b.export_date = l.export_date
)

select
    upper(trim(k_number))                                       as k_number,
    raw:applicant::string                                       as applicant,
    raw:device_name::string                                     as device_name,
    raw:product_code::string                                    as product_code,
    raw:openfda:device_class::string                            as device_class,
    raw:openfda:regulation_number::string                       as regulation_number,
    raw:advisory_committee::string                              as review_panel_code,
    raw:advisory_committee_description::string                  as review_panel,
    try_to_date(raw:decision_date::string)                      as decision_date,
    try_to_date(raw:date_received::string)                      as date_received,
    raw:decision_code::string                                   as decision_code,
    raw:clearance_type::string                                  as clearance_type,
    -- About 56k older records have this blank; store it as null, not ''.
    nullif(trim(raw:statement_or_summary::string), '')          as statement_or_summary,
    export_date
from records
-- Guard against duplicate records inside one export.
qualify row_number() over (partition by upper(trim(k_number)) order by raw:decision_date::string desc) = 1