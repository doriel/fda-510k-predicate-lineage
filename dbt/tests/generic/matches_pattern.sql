{# Fails for non-null values that do not match a regular expression. #}
{% test matches_pattern(model, column_name, pattern) %}

select *
from {{ model }}
where {{ column_name }} is not null
  and not ({{ column_name }} rlike '{{ pattern }}')

{% endtest %}