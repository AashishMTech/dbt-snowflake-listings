{% macro _resolve_usage_examples(listing_manifest, share_objects) %}
    {#
        Points <database>.<schema>.<object> names in usage_examples queries at the schema the object
        is shared from.

        Snowflake checks that every object a usage example query names is granted to the share and
        rejects the listing with "Schema ... is not granted to share" otherwise. Like data_dictionary
        (see _resolve_data_dictionary), the share can resolve a model to another schema than the one
        written in the query, e.g. a CI run that rebuilds a model into a PR schema. A name that is
        already shared as written is kept; otherwise, when exactly one share object in that database
        has that name, only the schema part is replaced (quoting and the other parts are kept).
        Anything else is left unchanged. Uses string operations only, no regex.

        Args:
            listing_manifest: The listing_manifest dict from the model config
            share_objects: List of dicts with 'database', 'schema', 'name' keys

        Returns:
            A copy of listing_manifest with resolved queries (the config is not mutated)
    #}
    {% set examples = listing_manifest.get('usage_examples') %}
    {% if examples is string or examples is mapping or not examples %}
        {{ return(listing_manifest) }}
    {% endif %}

    {% set shared = [] %}
    {% for obj in share_objects %}
        {% do shared.append((obj['database'] | upper) ~ '.' ~ (obj['schema'] | upper) ~ '.' ~ (obj['name'] | upper)) %}
    {% endfor %}
    {% set ident_chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_$."' %}

    {% set resolved_examples = [] %}
    {% for example in examples %}
        {% set query = example.get('query') if example is mapping else none %}
        {% if query is string %}
            {# Tokens that look like a three-part name #}
            {% set flat = namespace(text=query) %}
            {% for sep in ['\n', '\r', '\t', '(', ')', ',', ';', '='] %}
                {% set flat.text = flat.text | replace(sep, ' ') %}
            {% endfor %}
            {% set tokens = [] %}
            {% for token in flat.text.split(' ') %}
                {% if token.split('.') | length == 3 and token not in tokens %}
                    {% do tokens.append(token) %}
                {% endif %}
            {% endfor %}

            {% set result = namespace(query=query) %}
            {% for token in tokens %}
                {% set p = token.split('.') %}
                {% set db = p[0] | replace('"', '') | upper %}
                {% set schema = p[1] | replace('"', '') | upper %}
                {% set name = p[2] | replace('"', '') | upper %}
                {% set candidates = [] %}
                {% for obj in share_objects %}
                    {% if (obj['database'] | upper) == db and (obj['name'] | upper) == name %}
                        {% do candidates.append(obj['schema'] | upper) %}
                    {% endif %}
                {% endfor %}
                {% if (db ~ '.' ~ schema ~ '.' ~ name) not in shared and candidates | length == 1 %}
                    {% set quote = '"' if p[1].startswith('"') else '' %}
                    {% set new_token = p[0] ~ '.' ~ quote ~ candidates[0] ~ quote ~ '.' ~ p[2] %}
                    {# Replace only where the token is not part of a longer name #}
                    {% set pieces = result.query.split(token) %}
                    {% set out = [pieces[0]] %}
                    {% for piece in pieces[1:] %}
                        {% set before = pieces[loop.index0] %}
                        {% set whole = (before == '' or before[-1] not in ident_chars)
                                       and (piece == '' or piece[0] not in ident_chars) %}
                        {% do out.append(new_token if whole else token) %}
                        {% do out.append(piece) %}
                    {% endfor %}
                    {% set result.query = out | join('') %}
                    {{ dbt_snowflake_listings._log_action(
                        'RESOLVE', 'USAGE EXAMPLE OBJECT', name, schema ~ ' -> ' ~ candidates[0]
                    ) }}
                {% endif %}
            {% endfor %}

            {% set resolved_example = {} %}
            {% for key, value in example.items() %}
                {% do resolved_example.update({key: result.query if key == 'query' else value}) %}
            {% endfor %}
            {% do resolved_examples.append(resolved_example) %}
        {% else %}
            {% do resolved_examples.append(example) %}
        {% endif %}
    {% endfor %}

    {% set resolved_manifest = {} %}
    {% for key, value in listing_manifest.items() %}
        {% do resolved_manifest.update({key: resolved_examples if key == 'usage_examples' else value}) %}
    {% endfor %}

    {{ return(resolved_manifest) }}
{% endmacro %}
