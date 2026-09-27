{# Fails for rows where two columns hold the same value. #}
{% test columns_differ(model, column_a, column_b) %}

select *
from {{ model }}
where {{ column_a }} = {{ column_b }}

{% endtest %}