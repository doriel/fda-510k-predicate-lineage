{#
  Turn a device or company name into a set of comparable words.

  Normalization, calibrated on the first review of name-only predicates (2026-09-28):
  - lowercase, accents removed ("Müller" -> "muller");
  - "TM" glued to a word removed ("MetalTM" -> "metal");
  - dots removed so abbreviations stay one word ("P.F.C." -> "pfc", "P.C.A." -> "pca");
  - any other symbol becomes a space (®, ™, "/", "-", punctuation);
  - words of 1 character and generic words dropped;
  - a final "s" removed from words longer than 3 letters ("shells" -> "shell").

  Stopwords are words that appear in thousands of names and would make any two
  names look similar (company suffixes, "system", "medical", "orthopaedics").
  Device words like "hip", "femoral" or "stem" are kept: they carry meaning.
#}
{% macro name_tokens(column) -%}
array_distinct(
    transform(
        filter(
            split(
                trim(
                    regexp_replace(
                        regexp_replace(
                            regexp_replace(
                                translate(lower(coalesce({{ column }}, '')),
                                          'áàâäãåéèêëíìîïóòôöõúùûüçñ',
                                          'aaaaaaeeeeiiiiooooouuuucn'),
                                'tm\\b', ' '),
                            '\\.', ''),
                        '[^a-z0-9]+', ' ')
                ),
                ' '
            ),
            t -> length(t) >= 2 and not array_contains(
                array(
                    'the', 'and', 'with', 'of', 'for', 'by',
                    'system', 'systems', 'device', 'devices',
                    'inc', 'incorporated', 'corp', 'corporation', 'co', 'company', 'ltd', 'limited',
                    'llc', 'gmbh', 'sa', 'ag', 'plc', 'bv', 'spa', 'srl',
                    'international', 'usa', 'america', 'medical', 'technologies', 'technology', 'industries',
                    'orthopaedic', 'orthopaedics', 'orthopedic', 'orthopedics'
                ),
                t
            )
        ),
        t -> if(length(t) > 3 and t like '%s', left(t, length(t) - 1), t)
    )
)
{%- endmacro %}


{# Jaccard similarity of two word arrays: shared words / all words. Null when both are empty. #}
{% macro jaccard(a, b) -%}
case
    when size(array_union({{ a }}, {{ b }})) = 0 then null
    else size(array_intersect({{ a }}, {{ b }})) / size(array_union({{ a }}, {{ b }}))
end
{%- endmacro %}