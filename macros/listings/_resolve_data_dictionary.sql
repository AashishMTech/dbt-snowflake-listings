{% macro _resolve_data_dictionary(listing_manifest, share_objects) %}
    {#
        Points each data_dictionary.featured object at the schema its share object resolved to.

        The share is built from ref() relations, which can resolve to another schema than the one
        written in the manifest (e.g. a CI run that rebuilds a model into a PR schema while the
        rest defer to prod). Snowflake then rejects the listing with "Data Dictionary featured
        object ... is not granted to the share". Featured objects that are already shared as
        written are kept; otherwise the share object with the same name is used when there is
        exactly one in the featured database. Anything else is left unchanged.

        Args:
            listing_manifest: The listing_manifest dict from the model config
            share_objects: List of dicts with 'database', 'schema', 'name' keys

        Returns:
            A copy of listing_manifest with resolved featured schemas (the config is not mutated)
    #}
    {% set data_dictionary = listing_manifest.get('data_dictionary') %}
    {% set featured = data_dictionary.get('featured') if data_dictionary is mapping else none %}
    {% if featured is not mapping or not featured.get('objects') %}
        {{ return(listing_manifest) }}
    {% endif %}

    {% set featured_db = featured.get('database', '') | upper %}
    {% set shared = [] %}
    {% for obj in share_objects %}
        {% do shared.append(
            (obj['database'] | upper) ~ '.' ~ (obj['schema'] | upper) ~ '.' ~ (obj['name'] | upper)
        ) %}
    {% endfor %}

    {% set resolved_objects = [] %}
    {% for item in featured['objects'] %}
        {% set schema = item.get('schema', '') | upper %}
        {% set name = item.get('name', '') | upper %}
        {% set resolved_schema = [] %}

        {% if (featured_db ~ '.' ~ schema ~ '.' ~ name) not in shared %}
            {% set candidates = [] %}
            {% for obj in share_objects %}
                {% if (obj['database'] | upper) == featured_db and (obj['name'] | upper) == name %}
                    {% do candidates.append(obj['schema'] | upper) %}
                {% endif %}
            {% endfor %}
            {% if candidates | length == 1 %}
                {% do resolved_schema.append(candidates[0]) %}
                {{ dbt_snowflake_listings._log_action(
                    'RESOLVE', 'DATA DICTIONARY OBJECT', name, schema ~ ' -> ' ~ candidates[0]
                ) }}
            {% endif %}
        {% endif %}

        {% set resolved_item = {} %}
        {% for key, value in item.items() %}
            {% if key == 'schema' and resolved_schema %}
                {% do resolved_item.update({key: resolved_schema[0]}) %}
            {% else %}
                {% do resolved_item.update({key: value}) %}
            {% endif %}
        {% endfor %}
        {% do resolved_objects.append(resolved_item) %}
    {% endfor %}

    {% set resolved_featured = {} %}
    {% for key, value in featured.items() %}
        {% do resolved_featured.update({key: resolved_objects if key == 'objects' else value}) %}
    {% endfor %}

    {% set resolved_data_dictionary = {} %}
    {% for key, value in data_dictionary.items() %}
        {% do resolved_data_dictionary.update({key: resolved_featured if key == 'featured' else value}) %}
    {% endfor %}

    {% set resolved_manifest = {} %}
    {% for key, value in listing_manifest.items() %}
        {% do resolved_manifest.update({key: resolved_data_dictionary if key == 'data_dictionary' else value}) %}
    {% endfor %}

    {{ return(resolved_manifest) }}
{% endmacro %}
