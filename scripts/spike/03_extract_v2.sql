-- =============================================================================
-- Extraction spike v2: predicate devices from parsed 510(k) summaries
-- Changes from v1, based on reading the source PDFs:
--   * Items listed under a "Predicate devices" heading are predicates, however
--     many (K123598 lists ~100 real predicates, not a reference list).
--   * Predicates the document never identifies are kept as rows with null
--     identity (K960395 compares against "Predicated device 1/2", unnamed).
--   * New field identifier_type: a predicate can have a K-number, be 510(k)
--     exempt ("Class I", like Mepitac in K121819), have a PMA/De Novo number,
--     or have no identifier at all.
--   * Evidence is optional and shorter, and max_tokens is raised, so long
--     predicate lists are not cut off.
--   * Results go to a new table with a prompt_version column, so v1 and v2
--     can be compared side by side.
-- Run each block on its own (select it, then Ctrl+Enter).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Extract (same 6 documents as v1)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE bootcamp_students.doriel.fda_spike_extracted_v2 AS
WITH docs AS (
  SELECT
    k_number,
    concat_ws('\n\n', transform(parsed:document:elements::array<variant>, e -> e:content::string)) AS doc_text
  FROM bootcamp_students.doriel.fda_spike_parsed
  WHERE k_number IN ('K960395', 'K123598', 'K121819', 'K031909', 'K240267', 'K192352')
)
SELECT
  k_number,
  'v2' AS prompt_version,
  ai_query(
    'databricks-claude-sonnet-4-5',
    concat(
      'You extract structured data from FDA 510(k) summary documents. ',
      'The text was parsed from PDFs: some pages are OCR from old scans or faxes, some text is handwritten, and tables appear as HTML.\n\n',
      'Rules:\n',
      '1. A PREDICATE is a legally marketed device the submitter claims substantial equivalence to. ',
      'Every item listed under a heading such as "Predicate devices" or "Legally marketed devices", ',
      'and every predicate column in a comparison table, is a predicate. Lists can be long (100+ items): include ALL of them, do not summarize or truncate.\n',
      '2. A REFERENCE device is cited only to support a specific feature or test, without a substantial equivalence claim. Use role "reference".\n',
      '3. Ignore K-numbers that are neither predicates nor reference devices, for example numbers inside the FDA clearance letter or page headers.\n',
      '4. identifier_type:\n',
      '   - "k_number": a 510(k) number is given (K followed by 6 digits).\n',
      '   - "pma": a PMA number is given (P followed by 6 digits).\n',
      '   - "de_novo": a De Novo number is given (DEN followed by 6 digits).\n',
      '   - "exempt": the document says the device is Class I or 510(k) exempt instead of giving a number.\n',
      '   - "none": the device is named but no identifier or exemption is stated.\n',
      '   - "unidentified": the document compares against a predicate but never names it (for example a column headed "Predicate device 1" with no name anywhere). Keep it as a row with nulls.\n',
      '5. identifier: the number exactly as written, normalized to uppercase and without spaces (K123456, P123456, DEN123456). Null if none. ',
      'Never invent or correct a number. If it looks garbled by OCR or handwriting, still copy it and set ocr_suspect to true.\n',
      '6. Do not list the document own number (given below) as a predicate, including handwritten or OCR variants of it.\n',
      '7. Ignore FDA letter boilerplate, fax headers, page numbers and signatures.\n',
      '8. evidence: at most 10 words copied from the document. Use null for items in a long list (more than 10 items).\n',
      '9. predicates_declared: how many predicates the document says it compares against, counting unidentified ones. ',
      'It must equal the number of items with role "predicate".\n',
      '10. If the document names no predicates at all, return an empty list and explain why in extraction_notes. Do not guess.\n\n',
      'Document number: ', k_number, '\n\n',
      '<document>\n', doc_text, '\n</document>'
    ),
    responseFormat => '{
      "type": "json_schema",
      "json_schema": {
        "name": "predicate_extraction",
        "strict": true,
        "schema": {
          "type": "object",
          "additionalProperties": false,
          "required": ["subject_device_name", "applicant", "predicates_declared", "predicates", "extraction_notes"],
          "properties": {
            "subject_device_name": {"type": ["string", "null"]},
            "applicant":           {"type": ["string", "null"]},
            "predicates_declared": {"type": "integer"},
            "predicates": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["identifier_type", "identifier", "device_name", "manufacturer", "role", "ocr_suspect", "evidence"],
                "properties": {
                  "identifier_type": {"type": "string", "enum": ["k_number", "pma", "de_novo", "exempt", "none", "unidentified"]},
                  "identifier":      {"type": ["string", "null"]},
                  "device_name":     {"type": ["string", "null"]},
                  "manufacturer":    {"type": ["string", "null"]},
                  "role":            {"type": "string", "enum": ["predicate", "reference"]},
                  "ocr_suspect":     {"type": "boolean"},
                  "evidence":        {"type": ["string", "null"]}
                }
              }
            },
            "extraction_notes": {"type": ["string", "null"]}
          }
        }
      }
    }',
    modelParameters => named_struct('max_tokens', 16000, 'temperature', 0.0),
    failOnError => false
  ) AS extraction,
  current_timestamp() AS extracted_at
FROM docs;


-- -----------------------------------------------------------------------------
-- 2. Errors, and whether the item count matches what the model says it declared
-- -----------------------------------------------------------------------------
SELECT
  k_number,
  extraction.errorMessage                                        AS error,
  r:predicates_declared::int                                     AS declared,
  size(filter(r:predicates::array<variant>,
              p -> p:role::string = 'predicate'))                AS extracted_predicates,
  size(filter(r:predicates::array<variant>,
              p -> p:role::string = 'reference'))                AS extracted_references,
  r:extraction_notes::string                                     AS notes
FROM (
  SELECT k_number, extraction, try_parse_json(extraction.result) AS r
  FROM bootcamp_students.doriel.fda_spike_extracted_v2
)
ORDER BY k_number;


-- -----------------------------------------------------------------------------
-- 3. One row per extracted item
-- -----------------------------------------------------------------------------
SELECT
  k_number                           AS subject_k_number,
  p.value:role::string               AS role,
  p.value:identifier_type::string    AS identifier_type,
  p.value:identifier::string         AS identifier,
  p.value:device_name::string        AS device_name,
  p.value:manufacturer::string       AS manufacturer,
  p.value:ocr_suspect::boolean       AS ocr_suspect,
  p.value:evidence::string           AS evidence
FROM (
  SELECT k_number, try_parse_json(extraction.result) AS r
  FROM bootcamp_students.doriel.fda_spike_extracted_v2
),
LATERAL variant_explode(r:predicates) AS p
ORDER BY subject_k_number, role, identifier;
