if Code.ensure_loaded?(Ecto) do
  defmodule Phoenix.Sync.EctoShape do
    @moduledoc false

    alias Ecto.Query
    alias Electric.Client.EctoAdapter
    alias Electric.Client.ShapeDefinition

    @unsupported_query_parts [
      {:order_bys, "ORDER BY"},
      {:limit, "LIMIT"},
      {:offset, "OFFSET"},
      {:group_bys, "GROUP BY"},
      {:havings, "HAVING"},
      {:distinct, "DISTINCT"},
      {:preloads, "PRELOAD"},
      {:assocs, "association preload"},
      {:combinations, "set combination"},
      {:windows, "window"},
      {:lock, "lock"}
    ]

    @spec shape!(term(), keyword()) :: ShapeDefinition.t()
    def shape!(queryable, opts \\ [])

    def shape!(%Query{} = query, opts) do
      validate_query!(query)

      case {query.joins, subquery_predicates?(query)} do
        {[], false} -> simple_shape!(query, opts)
        {[], true} -> subquery_shape!(query, opts)
        {[_ | _], _subqueries?} -> relationship_shape!(query, opts)
      end
    end

    def shape!(queryable, opts), do: simple_shape!(queryable, opts)

    defp relationship_shape!(query, opts) do
      validate_select!(query)

      sources = sources(query)
      edges = relationship_edges(query, sources)

      relationship_shape!(
        query,
        opts,
        edges,
        sources,
        mixed_boolean_predicates?(query) or subquery_predicates?(query)
      )
    end

    defp subquery_shape!(query, opts) do
      root_shape = query |> Map.put(:wheres, []) |> simple_shape!(opts)
      predicate_where = boolean_where(query.wheres, [], sources(query))

      %{root_shape | where: combine_where([root_shape.where, predicate_where])}
    end

    defp relationship_shape!(query, opts, edges, sources, false) do
      wheres = wheres_by_binding(query)
      root_wheres = Map.get(wheres, 0, [])

      root_query = %{query | joins: [], wheres: root_wheres}
      root_shape = simple_shape!(root_query, opts)
      relationship_where = relationship_where(0, edges, wheres, sources)

      %{root_shape | where: combine_where([root_shape.where, relationship_where])}
    end

    defp relationship_shape!(query, opts, edges, sources, true) do
      root_query = %{query | joins: [], wheres: []}
      root_shape = simple_shape!(root_query, opts)
      join_where = relationship_where(0, edges, %{}, sources)
      predicate_where = boolean_where(query.wheres, edges, sources)

      %{root_shape | where: combine_where([join_where, predicate_where])}
    end

    defp validate_query!(query) do
      Enum.each(@unsupported_query_parts, fn {key, label} ->
        if query_part_present?(Map.fetch!(query, key)) do
          raise ArgumentError,
            message:
              "Ecto #{label} cannot be represented by an Electric shape. " <>
                query_part_guidance(key)
        end
      end)

      if query.with_ctes && query.with_ctes.queries != [] do
        raise ArgumentError,
          message: "Ecto CTEs cannot be represented by an Electric shape"
      end

      if query.select && aggregate_expression?(query.select.expr) do
        raise ArgumentError,
          message:
            "Ecto aggregates cannot be represented by an Electric shape. " <>
              "A shape must remain a row-level subset of one root table as changes arrive."
      end
    end

    defp query_part_present?(nil), do: false
    defp query_part_present?([]), do: false
    defp query_part_present?(%Ecto.Query.ByExpr{expr: []}), do: false
    defp query_part_present?(_value), do: true

    defp query_part_guidance(key) when key in [:order_bys, :limit, :offset] do
      "Use a subset snapshot for ordered or paginated initial data; it is a snapshot, not a live ordered result."
    end

    defp query_part_guidance(key) when key in [:preloads, :assocs] do
      "A shape streams rows from one root table and cannot return an association graph."
    end

    defp query_part_guidance(_key) do
      "A shape must remain a row-level subset of one root table as changes arrive."
    end

    defp aggregate_expression?(expression) do
      {_expression, aggregate?} =
        Macro.prewalk(expression, false, fn
          {name, _, args} = expression, _aggregate?
          when name in [:count, :avg, :sum, :min, :max] and is_list(args) ->
            {expression, true}

          expression, aggregate? ->
            {expression, aggregate?}
        end)

      aggregate?
    end

    defp mixed_boolean_predicates?(query) do
      Enum.any?(query.wheres, fn where ->
        where.op != :and or MapSet.size(binding_references(where.expr)) > 1
      end)
    end

    defp subquery_predicates?(query) do
      Enum.any?(query.wheres, &subquery_expression?(&1.expr))
    end

    defp subquery_expression?(expression) do
      {_expression, subquery?} =
        Macro.prewalk(expression, false, fn
          {:subquery, _index} = expression, _subquery? -> {expression, true}
          expression, subquery? -> {expression, subquery?}
        end)

      subquery?
    end

    defp validate_select!(%Query{select: nil}), do: :ok

    defp validate_select!(%Query{select: select}) do
      case binding_references(select.expr) |> MapSet.delete(0) |> MapSet.to_list() do
        [] ->
          :ok

        bindings ->
          raise ArgumentError,
            message:
              "An Electric relationship shape can only select the root Ecto binding; " <>
                "the select references joined bindings #{inspect(bindings)}"
      end
    end

    defp sources(query) do
      root = source!(query.from.source, query.from.prefix, 0)

      query.joins
      |> Enum.with_index(1)
      |> Enum.reduce(%{0 => root}, fn {join, binding}, sources ->
        Map.put(sources, binding, join_source!(join, sources, binding))
      end)
    end

    defp join_source!(%{assoc: {parent, association}, source: nil} = join, sources, binding) do
      association = association!(sources[parent].schema, association, binding)
      source!({nil, association.related}, join.prefix, binding)
    end

    defp join_source!(join, _sources, binding) do
      source!(join.source, join.prefix, binding)
    end

    defp source!({_table, schema}, prefix, _binding) when is_atom(schema) do
      schema_query = Ecto.Queryable.to_query(schema)
      {table, ^schema} = schema_query.from.source

      %{table: table, schema: schema, prefix: prefix || schema_query.from.prefix}
    end

    defp source!(source, _prefix, binding) do
      raise ArgumentError,
        message:
          "Ecto join binding #{binding} uses unsupported source #{inspect(source)}. " <>
            "Relationship joins must use Ecto schema modules."
    end

    defp relationship_edges(query, sources) do
      query.joins
      |> Enum.with_index(1)
      |> Enum.map(fn {join, child_binding} ->
        if join.qual != :inner do
          raise ArgumentError,
            message:
              "Electric relationship shapes only support Ecto inner joins, got: " <>
                inspect(join.qual)
        end

        {parent_binding, parent_fields, child_fields, filter} =
          relationship_fields!(join, child_binding, sources)

        %{
          parent: parent_binding,
          parent_fields:
            Enum.map(parent_fields, &field_source(sources[parent_binding].schema, &1)),
          child: child_binding,
          child_fields: Enum.map(child_fields, &field_source(sources[child_binding].schema, &1)),
          where: join_filter_where(filter, join.on, child_binding, sources)
        }
      end)
    end

    defp relationship_fields!(
           %{assoc: {parent, association}, source: nil, on: %{expr: true}},
           _child_binding,
           sources
         ) do
      association = association!(sources[parent].schema, association, parent)
      {parent, [association.owner_key], [association.related_key], nil}
    end

    defp relationship_fields!(
           %{assoc: {parent, association}, source: nil, on: %{expr: filter}},
           child_binding,
           sources
         ) do
      association = association!(sources[parent].schema, association, parent)
      filter = join_filter!(filter, child_binding)

      {parent, [association.owner_key], [association.related_key], filter}
    end

    defp relationship_fields!(join, child_binding, _sources) do
      {relationships, filters} =
        join.on.expr
        |> conjunction_parts()
        |> Enum.reduce({[], []}, fn expression, {relationships, filters} ->
          case relationship_equality(expression, child_binding) do
            {:ok, relationship} ->
              {[relationship | relationships], filters}

            :error ->
              {relationships, [join_filter!(expression, child_binding) | filters]}
          end
        end)

      case relationships |> Enum.reverse() |> Enum.group_by(&elem(&1, 0)) |> Map.to_list() do
        [{parent_binding, relationships}] ->
          {parent_fields, child_fields} =
            Enum.map(relationships, fn {_parent_binding, parent_field, child_field} ->
              {parent_field, child_field}
            end)
            |> Enum.unzip()

          {parent_binding, parent_fields, child_fields, combine_and(Enum.reverse(filters))}

        _relationships ->
          raise ArgumentError,
            message:
              "Ecto join binding #{child_binding} must equate its fields with fields from " <>
                "one earlier binding"
      end
    end

    defp relationship_equality({:==, _, [left, right]}, child_binding) do
      with {:ok, {left_binding, left_field}} <- field_reference(left),
           {:ok, {right_binding, right_field}} <- field_reference(right) do
        {:ok,
         orient_relationship!(
           {left_binding, left_field, right_binding, right_field},
           child_binding
         )}
      else
        _ -> :error
      end
    end

    defp relationship_equality(_expression, _child_binding), do: :error

    defp join_filter!(expression, child_binding) do
      case MapSet.to_list(binding_references(expression)) do
        [] ->
          expression

        [^child_binding] ->
          expression

        bindings ->
          raise ArgumentError,
            message:
              "Ecto join binding #{child_binding} has an ON filter referencing bindings " <>
                "#{inspect(bindings)}. ON filters may reference only the joined binding."
      end
    end

    defp conjunction_parts({:and, _, [left, right]}) do
      conjunction_parts(left) ++ conjunction_parts(right)
    end

    defp conjunction_parts(expression), do: [expression]

    defp combine_and([]), do: nil
    defp combine_and([expression]), do: expression

    defp combine_and([expression | expressions]) do
      Enum.reduce(expressions, expression, &{:and, [], [&2, &1]})
    end

    defp join_filter_where(nil, _on, _child_binding, _sources), do: nil

    defp join_filter_where(filter, on, child_binding, sources) do
      where = %Ecto.Query.BooleanExpr{
        op: :and,
        expr: on.expr,
        params: on.params,
        subqueries: [],
        file: on.file,
        line: on.line
      }

      expression_where(child_binding, filter, where, sources)
    end

    defp orient_relationship!(
           {child_binding, child_field, parent_binding, parent_field},
           child_binding
         )
         when parent_binding < child_binding,
         do: {parent_binding, parent_field, child_field}

    defp orient_relationship!(
           {parent_binding, parent_field, child_binding, child_field},
           child_binding
         )
         when parent_binding < child_binding,
         do: {parent_binding, parent_field, child_field}

    defp orient_relationship!(_relationship, child_binding) do
      raise ArgumentError,
        message:
          "Ecto join binding #{child_binding} must equate one of its fields with a field " <>
            "from an earlier binding"
    end

    defp association!(schema, field, binding) do
      case schema.__schema__(:association, field) do
        %{where: []} = association ->
          association

        %{where: [_ | _]} ->
          raise ArgumentError,
            message:
              "Ecto association join binding #{binding} uses association-level filters, " <>
                "which cannot be represented by an Electric relationship shape"

        nil ->
          raise ArgumentError,
            message: "Unknown Ecto association #{inspect(field)} on #{inspect(schema)}"
      end
    end

    defp field_reference({{:., _, [{:&, _, [binding]}, field]}, _, []}) when is_atom(field),
      do: {:ok, {binding, field}}

    defp field_reference(_expression), do: :error

    defp wheres_by_binding(query) do
      Enum.group_by(query.wheres, fn where ->
        case MapSet.to_list(binding_references(where.expr)) do
          [] ->
            0

          [binding] ->
            binding

          bindings ->
            raise ArgumentError,
              message:
                "An Ecto predicate references multiple Ecto bindings #{inspect(bindings)}. " <>
                  "Electric relationship predicates must apply to one table at a time."
        end
      end)
    end

    defp binding_references(expression) do
      {_expression, bindings} =
        Macro.prewalk(expression, MapSet.new(), fn
          {:&, _, [binding]} = expression, bindings ->
            {expression, MapSet.put(bindings, binding)}

          expression, bindings ->
            {expression, bindings}
        end)

      bindings
    end

    defp boolean_where([], _edges, _sources), do: nil

    defp boolean_where([where | wheres], edges, sources) do
      initial = boolean_expression(where.expr, where, edges, sources)

      Enum.reduce(wheres, initial, fn where, expression ->
        combine_boolean(
          expression,
          where.op,
          boolean_expression(where.expr, where, edges, sources)
        )
      end)
    end

    defp boolean_expression({operator, _, [left, right]}, where, edges, sources)
         when operator in [:and, :or] do
      combine_boolean(
        boolean_expression(left, where, edges, sources),
        operator,
        boolean_expression(right, where, edges, sources)
      )
    end

    defp boolean_expression({:in, _, [left, {:subquery, index}]}, where, edges, sources) do
      {binding, left_fields} = membership_fields!(left, sources)
      subquery = Enum.fetch!(where.subqueries, index)

      left_fields
      |> membership_subquery!(subquery)
      |> relationship_predicate(binding, edges, sources)
    end

    defp boolean_expression({:not, _, [expression]}, where, edges, sources) do
      if subquery_expression?(expression) do
        raise ArgumentError,
          message:
            "Negative Ecto subquery membership cannot be represented safely without " <>
              "a non-null projected membership key"
      else
        ["NOT (", boolean_expression(expression, where, edges, sources), ")"]
        |> IO.iodata_to_binary()
      end
    end

    defp boolean_expression(expression, where, edges, sources) do
      if subquery_expression?(expression) do
        raise ArgumentError,
          message:
            "Ecto subqueries must be used as a direct positive IN predicate in " <>
              "where or or_where"
      else
        case MapSet.to_list(binding_references(expression)) do
          [] ->
            expression_where(0, expression, where, sources)

          [binding] ->
            binding
            |> expression_where(expression, where, sources)
            |> relationship_predicate(binding, edges, sources)

          bindings ->
            raise ArgumentError,
              message:
                "An Ecto predicate references multiple Ecto bindings #{inspect(bindings)}. " <>
                  "Electric relationship predicates must compare values from one table at a time."
        end
      end
    end

    defp combine_boolean(left, operator, right) do
      ["(", left, ") ", boolean_operator(operator), " (", right, ")"]
      |> IO.iodata_to_binary()
    end

    defp boolean_operator(:and), do: "AND"
    defp boolean_operator(:or), do: "OR"

    defp expression_where(binding, expression, where, sources) do
      source = sources[binding]
      query = source.schema |> Ecto.Queryable.to_query() |> put_source(source)

      query
      |> Map.put(:wheres, [where |> narrow_where(expression) |> rebind_where(binding)])
      |> simple_shape!([])
      |> Map.fetch!(:where)
    end

    defp narrow_where(where, expression) do
      indexes = parameter_indexes(expression)
      replacements = indexes |> Enum.with_index() |> Map.new()

      expression =
        Macro.prewalk(expression, fn
          {:^, meta, [index]} -> {:^, meta, [Map.fetch!(replacements, index)]}
          expression -> expression
        end)

      where = %{
        where
        | expr: expression,
          params: Enum.map(indexes, &Enum.fetch!(where.params, &1))
      }

      if Map.has_key?(where, :subqueries), do: %{where | subqueries: []}, else: where
    end

    defp membership_fields!(expression, sources) do
      fields = membership_field_expressions!(expression)

      {bindings, fields} =
        fields
        |> Enum.map(fn expression ->
          case field_reference(expression) do
            {:ok, reference} ->
              reference

            :error ->
              raise ArgumentError,
                message: "The left side of an Ecto IN subquery must contain only schema fields"
          end
        end)
        |> Enum.unzip()

      case Enum.uniq(bindings) do
        [binding] ->
          source = Map.fetch!(sources, binding)
          {binding, Enum.map(fields, &field_source(source.schema, &1))}

        bindings ->
          raise ArgumentError,
            message:
              "The left side of an Ecto IN subquery references multiple bindings " <>
                inspect(bindings)
      end
    end

    defp membership_field_expressions!(expression) do
      case field_reference(expression) do
        {:ok, _reference} ->
          [expression]

        :error ->
          row_membership_fields!(expression)
      end
    end

    defp row_membership_fields!({:fragment, _, [{:raw, open}, {:expr, first} | rest]}) do
      if String.trim(open) == "(" do
        consume_row_fragment!(rest, [first])
      else
        invalid_row_membership!()
      end
    end

    defp row_membership_fields!(_expression), do: invalid_row_membership!()

    defp consume_row_fragment!([{:raw, close}], fields) do
      if String.trim(close) == ")" do
        Enum.reverse(fields)
      else
        invalid_row_membership!()
      end
    end

    defp consume_row_fragment!([{:raw, comma}, {:expr, field} | rest], fields) do
      if Regex.match?(~r/^\s*,\s*$/, comma) do
        consume_row_fragment!(rest, [field | fields])
      else
        invalid_row_membership!()
      end
    end

    defp consume_row_fragment!(_parts, _fields), do: invalid_row_membership!()

    defp invalid_row_membership! do
      raise ArgumentError,
        message:
          "Row-valued Ecto IN subqueries require an exact " <>
            ~s|fragment("(?, ...)", field, ...)|
    end

    defp membership_subquery!(left_fields, %Ecto.SubQuery{query: query}) do
      validate_subquery!(query)

      source = source!(query.from.source, query.prefix || query.from.prefix, 0)
      selected_fields = subquery_select_fields!(query.select, source)

      if length(left_fields) != length(selected_fields) do
        raise ArgumentError,
          message:
            "Ecto IN subquery field count does not match its left side: " <>
              "#{length(left_fields)} != #{length(selected_fields)}"
      end

      where = boolean_where(query.wheres, [], %{0 => source})

      [
        quote_field_tuple(left_fields),
        " IN (SELECT ",
        Enum.map_join(selected_fields, ", ", &quote_identifier/1),
        " FROM ",
        quote_table(source),
        where_clause(where),
        ")"
      ]
      |> IO.iodata_to_binary()
    end

    defp validate_subquery!(query) do
      if correlated_query?(query) do
        raise ArgumentError,
          message:
            "Electric shapes do not support correlated Ecto subqueries; " <>
              "use an uncorrelated IN subquery"
      end

      validate_query!(query)

      if query.joins != [] do
        raise ArgumentError,
          message: "Ecto shape subqueries must read from one schema source without joins"
      end
    end

    defp correlated_query?(query) do
      expressions =
        Enum.map(query.wheres, & &1.expr) ++
          if(query.select, do: [query.select.expr], else: [])

      Enum.any?(expressions, &correlated_expression?/1)
    end

    defp correlated_expression?(expression) do
      {_expression, correlated?} =
        Macro.prewalk(expression, false, fn
          {:parent_as, _, _} = expression, _correlated? -> {expression, true}
          expression, correlated? -> {expression, correlated?}
        end)

      correlated?
    end

    defp subquery_select_fields!(%Ecto.Query.SelectExpr{expr: expression}, source) do
      expression
      |> subquery_select_expressions!()
      |> Enum.map(fn expression ->
        case field_reference(expression) do
          {:ok, {0, field}} ->
            field_source(source.schema, field)

          _ ->
            raise ArgumentError,
              message: "Ecto shape subqueries must select plain fields from their source schema"
        end
      end)
    end

    defp subquery_select_fields!(_select, _source) do
      raise ArgumentError,
        message: "Ecto shape subqueries must select one or more source fields"
    end

    defp subquery_select_expressions!({:{}, _, [_ | _] = expressions}), do: expressions
    defp subquery_select_expressions!(expression), do: [expression]

    defp parameter_indexes(expression) do
      {_expression, indexes} =
        Macro.prewalk(expression, MapSet.new(), fn
          {:^, _, [index]} = expression, indexes ->
            {expression, MapSet.put(indexes, index)}

          expression, indexes ->
            {expression, indexes}
        end)

      Enum.sort(indexes)
    end

    defp relationship_predicate(where, 0, _edges, _sources), do: where

    defp relationship_predicate(where, binding, edges, sources) do
      edge = Enum.find(edges, &(&1.child == binding))
      where = relationship_subquery(edge, sources[binding], where)

      relationship_predicate(where, edge.parent, edges, sources)
    end

    defp relationship_where(parent, edges, wheres, sources) do
      edges
      |> Enum.filter(&(&1.parent == parent))
      |> Enum.map(fn edge ->
        child_where = source_where(edge.child, wheres, sources)
        nested_where = relationship_where(edge.child, edges, wheres, sources)
        where = combine_where([child_where, nested_where])
        source = sources[edge.child]

        relationship_subquery(edge, source, where)
      end)
      |> combine_where()
    end

    defp relationship_subquery(edge, source, where) do
      where = combine_where([edge.where, where])

      [
        quote_field_tuple(edge.parent_fields),
        " IN (SELECT ",
        Enum.map_join(edge.child_fields, ", ", &quote_identifier/1),
        " FROM ",
        quote_table(source),
        where_clause(where),
        ")"
      ]
      |> IO.iodata_to_binary()
    end

    defp where_clause(where) when where in [nil, ""], do: []
    defp where_clause(where), do: [" WHERE ", where]

    defp source_where(binding, wheres, sources) do
      case Map.get(wheres, binding, []) do
        [] ->
          nil

        wheres ->
          source = sources[binding]
          query = source.schema |> Ecto.Queryable.to_query() |> put_source(source)

          query
          |> Map.put(:wheres, Enum.map(wheres, &rebind_where(&1, binding)))
          |> simple_shape!([])
          |> Map.fetch!(:where)
      end
    end

    defp put_source(query, source) do
      from = %{query.from | source: {source.table, source.schema}, prefix: source.prefix}
      %{query | from: from}
    end

    defp rebind_where(where, binding) do
      %{
        where
        | expr: rebind_expression(where.expr, binding),
          params: Enum.map(where.params, &rebind_param(&1, binding))
      }
    end

    defp rebind_expression({:&, meta, [binding]}, binding), do: {:&, meta, [0]}

    defp rebind_expression(%Ecto.Query.Tagged{} = tagged, binding) do
      %{tagged | type: rebind_type(tagged.type, binding)}
    end

    defp rebind_expression(tuple, binding) when is_tuple(tuple) do
      tuple
      |> Tuple.to_list()
      |> Enum.map(&rebind_expression(&1, binding))
      |> List.to_tuple()
    end

    defp rebind_expression(list, binding) when is_list(list),
      do: Enum.map(list, &rebind_expression(&1, binding))

    defp rebind_expression(value, _binding), do: value

    defp rebind_param({value, type}, binding), do: {value, rebind_type(type, binding)}

    defp rebind_type({binding, field}, binding) when is_atom(field), do: {0, field}

    defp rebind_type(tuple, binding) when is_tuple(tuple) do
      tuple
      |> Tuple.to_list()
      |> Enum.map(&rebind_type(&1, binding))
      |> List.to_tuple()
    end

    defp rebind_type(list, binding) when is_list(list),
      do: Enum.map(list, &rebind_type(&1, binding))

    defp rebind_type(value, _binding), do: value

    defp simple_shape!(queryable, opts) do
      queryable
      |> EctoAdapter.shape!(opts)
      |> cast_string_enum_columns(queryable)
    end

    defp cast_string_enum_columns(%ShapeDefinition{where: nil} = shape, _queryable), do: shape

    defp cast_string_enum_columns(%ShapeDefinition{} = shape, queryable) do
      case ecto_schema(queryable) do
        nil ->
          shape

        schema ->
          enum_columns =
            schema.__schema__(:fields)
            |> Enum.filter(&(schema.__schema__(:type, &1) |> string_enum?()))
            |> Enum.map(&(schema.__schema__(:field_source, &1) |> to_string()))

          %{shape | where: cast_quoted_columns(shape.where, enum_columns)}
      end
    end

    defp ecto_schema(schema) when is_atom(schema) do
      if Code.ensure_loaded?(schema) && function_exported?(schema, :__schema__, 1), do: schema
    end

    defp ecto_schema(%Query{from: %{source: {_table, schema}}}), do: schema
    defp ecto_schema(%Ecto.Changeset{data: %{__struct__: schema}}), do: schema
    defp ecto_schema(_queryable), do: nil

    defp string_enum?({:parameterized, {Ecto.Enum, %{type: :string}}}), do: true
    defp string_enum?(_type), do: false

    defp cast_quoted_columns(where, []), do: where

    defp cast_quoted_columns(where, columns) do
      ~r/('(?:''|[^'])*')/
      |> Regex.split(where, include_captures: true)
      |> Enum.map_join(fn
        <<"'", _::binary>> = literal ->
          literal

        sql ->
          Enum.reduce(columns, sql, fn column, sql ->
            quoted_column = quote_identifier(column)
            String.replace(sql, quoted_column, "(#{quoted_column}::text)")
          end)
      end)
    end

    defp field_source(schema, field), do: schema.__schema__(:field_source, field) |> to_string()

    defp quote_table(%{table: table, prefix: nil}), do: quote_identifier(table)

    defp quote_table(%{table: table, prefix: prefix}) do
      quote_identifier(prefix) <> "." <> quote_identifier(table)
    end

    defp quote_field_tuple([field]), do: quote_identifier(field)

    defp quote_field_tuple(fields) do
      "(" <> Enum.map_join(fields, ", ", &quote_identifier/1) <> ")"
    end

    defp quote_identifier(identifier) do
      ~s|"#{identifier |> to_string() |> String.replace(~s|"|, ~s|""|)}"|
    end

    defp combine_where(wheres) do
      case Enum.reject(wheres, &(&1 in [nil, ""])) do
        [] -> nil
        [where] -> where
        wheres -> Enum.map_join(wheres, " AND ", &"(#{&1})")
      end
    end
  end
end
