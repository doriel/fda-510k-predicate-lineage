-- =============================================================================
-- Extraction spike: predicate devices from parsed 510(k) summaries with ai_query
-- Run each block in its own %sql cell (or in the SQL Editor).
-- Input: bootcamp_students.doriel.fda_spike_parsed (output of ai_parse_document)
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Extract, on 6 hard cases from the parse spike
--    K960395  1996 fax scan, predicates cited by name only
--    K123598  ~100 K-numbers in the text, most are NOT predicates
--    K121819  mentions "K151819", a 2015 number inside a 2012 document
--    K031909  OCR misread its own number as "K631909"
--    K240267, K192352  clean modern documents (control group)
--
--    Replace the endpoint name with one that exists in your workspace
--    (Serving > Endpoints). A strong model matters more than cost here.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE bootcamp_students.doriel.fda_spike_extracted AS
WITH docs AS (
  SELECT
    k_number,
    -- Join all parsed elements (text, titles, HTML tables) into one document string.
    concat_ws('\n\n', transform(parsed:document:elements::array<variant>, e -> e:content::string)) AS doc_text
  FROM bootcamp_students.doriel.fda_spike_parsed
  WHERE k_number IN ('K960395', 'K123598', 'K121819', 'K031909', 'K240267', 'K192352')
)
SELECT
  k_number,
  ai_query(
    'databricks-claude-sonnet-4-5',
    concat(
      'You extract structured data from FDA 510(k) summary documents. ',
      'The text was parsed from PDFs: some pages are OCR from old scans or faxes, and tables appear as HTML.\n\n',
      'Rules:\n',
      '1. A PREDICATE is a legally marketed device that the submitter claims substantial equivalence to. ',
      'Look for phrases like "predicate device", "legally marketed device", "substantially equivalent to", ',
      'and for predicate columns in comparison tables.\n',
      '2. A REFERENCE device is cited for comparison of a specific feature or test, without a claim of substantial equivalence. ',
      'Include those with role "reference". Ignore any other K-numbers, for example lists of past clearances or numbers inside the FDA clearance letter.\n',
      '3. If a predicate is identified only by name (no K-number), include it with k_number null. ',
      'When a table header is generic (for example "Predicate device 1"), take the name and manufacturer from the surrounding text if present.\n',
      '4. Never invent or correct a K-number. Copy it as written, normalized to uppercase K followed by 6 digits. ',
      'If it looks garbled by OCR or is implausible, still copy it and set ocr_suspect to true.\n',
      '5. Do not list the document own K-number (given below) as a predicate or reference, including OCR variants of it.\n',
      '6. Ignore FDA letter boilerplate, fax headers, page numbers and signatures.\n',
      '7. evidence is a short excerpt (max 20 words) copied from the document that supports the item.\n',
      '8. If there are no predicates, return an empty list. Do not guess.\n\n',
      'Document K-number: ', k_number, '\n\n',
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
          "required": ["subject_device_name", "applicant", "predicates", "extraction_notes"],
          "properties": {
            "subject_device_name": {"type": ["string", "null"]},
            "applicant":           {"type": ["string", "null"]},
            "predicates": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["k_number", "device_name", "manufacturer", "role", "ocr_suspect", "evidence"],
                "properties": {
                  "k_number":     {"type": ["string", "null"]},
                  "device_name":  {"type": ["string", "null"]},
                  "manufacturer": {"type": ["string", "null"]},
                  "role":         {"type": "string", "enum": ["predicate", "reference"]},
                  "ocr_suspect":  {"type": "boolean"},
                  "evidence":     {"type": "string"}
                }
              }
            },
            "extraction_notes": {"type": ["string", "null"]}
          }
        }
      }
    }',
    failOnError => false
  ) AS extraction,
  current_timestamp() AS extracted_at
FROM docs;


-- -----------------------------------------------------------------------------
-- 2. Did any call fail?
-- -----------------------------------------------------------------------------
SELECT k_number, extraction.errorMessage
FROM bootcamp_students.doriel.fda_spike_extracted;


-- -----------------------------------------------------------------------------
-- 3. Document-level fields. Applicant and device name also exist in openFDA,
--    so they give free ground truth later.
-- -----------------------------------------------------------------------------
SELECT
  k_number,
  r:subject_device_name::string      AS subject_device_name,
  r:applicant::string                AS applicant,
  size(r:predicates::array<variant>) AS n_items,
  r:extraction_notes::string         AS notes
FROM (
  SELECT k_number, parse_json(extraction.result) AS r
  FROM bootcamp_students.doriel.fda_spike_extracted
);


-- -----------------------------------------------------------------------------
-- 4. One row per extracted predicate or reference device
-- -----------------------------------------------------------------------------
SELECT
  k_number                       AS subject_k_number,
  p.value:role::string           AS role,
  p.value:k_number::string       AS predicate_k_number,
  p.value:device_name::string    AS predicate_device_name,
  p.value:manufacturer::string   AS predicate_manufacturer,
  p.value:ocr_suspect::boolean   AS ocr_suspect,
  p.value:evidence::string       AS evidence
FROM (
  SELECT k_number, parse_json(extraction.result) AS r
  FROM bootcamp_students.doriel.fda_spike_extracted
),
LATERAL variant_explode(r:predicates) AS p
ORDER BY subject_k_number, role;
