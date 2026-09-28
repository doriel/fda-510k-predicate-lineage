{#
  Resolve every extracted citation against openFDA and give it a status (ADR 0004).

  Statuses:
    resolved          well-formed K-number, found in openFDA, cleared on or before the subject
    repaired          malformed K-number whose single repair candidate passes both checks
    resolved_by_name  cited by name only, confidently matched to one openFDA record
                      (int_name_resolution, match_status = matched)
    malformed         not K + 6 digits, and no repair candidate passes
    not_found         well-formed K-number that openFDA does not know
    date_violation    found in openFDA, but cleared after the subject device
    self_citation     the document's own number (should not happen; the prompt forbids it)
    exempt            510(k) exempt device, no number expected
    name_only         named device without an identifier, and no confident name match
    unidentified      predicate exists but is never named in the document
    other_pathway     PMA or De Novo number (resolution against other openFDA data is future work)

  resolution_method tells how the predicate was identified:
    identifier  from the K-number in the document (resolved, repaired)
    name_match  from the device name and company (resolved_by_name), less certain

  Repair rule (the only one, on purpose): a 7-digit K-number ending in 0 becomes the
  6-digit number without that 0 (K9903690 -> K990369, a typo seen in K123598).
  The repair is accepted only if the candidate exists and predates the subject.

  Joins on the citation key use null-safe equality (<=>) so unit test fixtures
  with partial keys behave like real data.

  Plain table: rebuilt from stored extractions, never calls the AI.
#}

with citations as (
    select * from {{ ref('int_predicate_citations') }}
),

openfda as (
    select k_number, decision_date, device_name, applicant, product_code
    from {{ ref('stg_openfda__submissions') }}
),

name_matches as (
    select
        subject_k_number, content_sha256, parser_version, prompt_version, model_endpoint, citation_seq,
        best_k_number,
        best_score
    from {{ ref('int_name_resolution') }}
    where match_status = 'matched'
),

candidates as (
    select
        c.*,
        nm.best_score as name_match_score,
        case
            when c.identifier_type = 'k_number' and c.is_well_formed
                then c.identifier_normalized
            when c.identifier_type = 'k_number' and c.identifier_normalized rlike '^K[0-9]{6}0$'
                then substr(c.identifier_normalized, 1, 7)
            when c.identifier_type = 'none'
                then nm.best_k_number
        end as candidate_k_number,
        case
            when c.identifier_type = 'k_number'
                 and not coalesce(c.is_well_formed, false)
                 and c.identifier_normalized rlike '^K[0-9]{6}0$'
                then 'drop_trailing_zero'
        end as candidate_repair_rule
    from citations as c
    left join name_matches as nm
        on  nm.subject_k_number <=> c.subject_k_number
        and nm.content_sha256   <=> c.content_sha256
        and nm.parser_version   <=> c.parser_version
        and nm.prompt_version   <=> c.prompt_version
        and nm.model_endpoint   <=> c.model_endpoint
        and nm.citation_seq     <=> c.citation_seq
),

joined as (
    select
        c.*,
        s.decision_date   as subject_decision_date,
        p.k_number        as found_k_number,
        p.decision_date   as found_decision_date,
        p.device_name     as found_device_name,
        p.applicant       as found_applicant,
        p.product_code    as found_product_code
    from candidates as c
    left join openfda as s on s.k_number = c.subject_k_number
    left join openfda as p on p.k_number = c.candidate_k_number
),

statused as (
    select
        *,
        case
            when identifier_type = 'exempt'                  then 'exempt'
            when identifier_type = 'unidentified'            then 'unidentified'
            when identifier_type in ('pma', 'de_novo')       then 'other_pathway'
            -- Name matching already enforces existence and date order.
            when identifier_type = 'none'
                then if(found_k_number is not null, 'resolved_by_name', 'name_only')
            when candidate_k_number is null                  then 'malformed'
            when candidate_k_number = subject_k_number       then 'self_citation'
            when found_k_number is null
                then if(candidate_repair_rule is not null, 'malformed', 'not_found')
            when found_decision_date > subject_decision_date
                then if(candidate_repair_rule is not null, 'malformed', 'date_violation')
            when candidate_repair_rule is not null           then 'repaired'
            else 'resolved'
        end as resolution_status
    from joined
)

select
    subject_k_number,
    content_sha256,
    parser_version,
    prompt_version,
    model_endpoint,
    citation_seq,
    role,
    identifier_type,
    identifier_raw,
    identifier_normalized,
    is_well_formed,
    device_name,
    manufacturer,
    ocr_suspect,
    evidence,
    resolution_status,
    case
        when resolution_status in ('resolved', 'repaired') then 'identifier'
        when resolution_status = 'resolved_by_name'        then 'name_match'
    end                                                                             as resolution_method,
    if(resolution_status in ('resolved', 'repaired', 'resolved_by_name'), candidate_k_number, null)
                                                                                    as resolved_k_number,
    if(resolution_status = 'repaired', candidate_repair_rule, null)                as repair_rule,
    if(resolution_status = 'resolved_by_name', name_match_score, null)             as name_match_score,
    subject_decision_date,
    if(found_k_number is not null, found_decision_date, null)                      as predicate_decision_date,
    -- False when either date is missing in openFDA, so the order could not be checked.
    (subject_decision_date is not null and found_decision_date is not null)        as date_order_checked,
    found_device_name                                                              as openfda_device_name,
    found_applicant                                                                as openfda_applicant,
    found_product_code                                                             as openfda_product_code
from statused