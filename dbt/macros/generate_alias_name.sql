{#
  Prefix every table and view this project creates with var('table_prefix'),
  so stg_openfda__submissions becomes fda_stg_openfda__submissions.
  The schema is shared with other projects; the prefix keeps them apart.
#}
{% macro generate_alias_name(custom_alias_name=none, node=none) -%}
    {{ var('table_prefix', '') ~ (custom_alias_name | trim if custom_alias_name else node.name) }}
{%- endmacro %}