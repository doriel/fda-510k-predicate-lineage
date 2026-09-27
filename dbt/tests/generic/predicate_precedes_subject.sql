{#
  Fails for rows where the predicate was cleared after the subject device.
  Rows with a missing date are skipped (they cannot be checked).
#}
{% test predicate_precedes_subject(model, subject_date, predicate_date) %}

select *
from {{ model }}
where {{ predicate_date }} > {{ subject_date }}

{% endtest %}