-- =============================================================================
-- Parse spike: run ai_parse_document on the PDFs from the feasibility check.
-- The PDFs were uploaded to a Unity Catalog Volume first:
--   databricks fs cp -r fda_check_out/pdfs dbfs:/Volumes/bootcamp_students/doriel/fda_raw_pdfs/
-- Results: 91 PDFs, 0 parse errors, about 170 seconds on notebook serverless.
-- A single-document call also worked on a serverless SQL warehouse (see ADR 0002).
-- =============================================================================

-- 1. Parse every PDF in the volume (one LLM-backed call per document).
CREATE OR REPLACE TABLE bootcamp_students.doriel.fda_spike_parsed AS
SELECT
  regexp_extract(path, '(K[0-9]{6})', 1) AS k_number,
  path,
  ai_parse_document(content) AS parsed
FROM READ_FILES('/Volumes/bootcamp_students/doriel/fda_raw_pdfs/', format => 'binaryFile');

-- 2. Errors, pages and elements per document.
SELECT
  k_number,
  parsed:error_status AS error_status,
  size(parsed:document:pages::array<variant>)    AS pages,
  size(parsed:document:elements::array<variant>) AS elements
FROM bootcamp_students.doriel.fda_spike_parsed
ORDER BY k_number;

-- 3. Regex baseline: other K-numbers mentioned in each document.
--    Useful as a recall check, not as an extractor (see ADR 0003).
WITH txt AS (
  SELECT
    k_number,
    concat_ws(' ', transform(parsed:document:elements::array<variant>, e -> e:content::string)) AS text
  FROM bootcamp_students.doriel.fda_spike_parsed
)
SELECT
  k_number,
  array_remove(array_distinct(transform(regexp_extract_all(text, '([Kk][0-9]{6})', 1), x -> upper(x))), k_number) AS other_k_numbers
FROM txt
ORDER BY k_number;

-- 4. Does ai_parse_document run on a SQL warehouse? (decides whether dbt owns the parse step)
SELECT ai_parse_document(content) IS NOT NULL AS parsed_ok
FROM READ_FILES('/Volumes/bootcamp_students/doriel/fda_raw_pdfs/K960395.pdf', format => 'binaryFile');
