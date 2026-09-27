{#
  Prompt and response schema for predicate extraction, version v2.

  This is the prompt validated in the extraction spike
  (docs/spikes/2026-09-extraction-spike.md). Any change to the wording or the
  schema must bump var('prompt_version'), so old and new results can be
  compared side by side (ADR 0005).

  Note: the prompt avoids apostrophes on purpose, because it is embedded in
  single-quoted SQL string literals.
#}

{% macro predicate_extraction_prompt(k_number_col, doc_text_col) -%}
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
    'Document number: ', {{ k_number_col }}, '\n\n',
    '<document>\n', {{ doc_text_col }}, '\n</document>'
)
{%- endmacro %}


{% macro predicate_extraction_response_format() -%}
'{
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
}'
{%- endmacro %}