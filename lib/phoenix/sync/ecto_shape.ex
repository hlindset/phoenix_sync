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

      case query.joins do
        [] -> simple_shape!(query, opts)
        [_ | _] -> relationship_shape!(query, opts)
      end
    end

    def shape!(queryable, opts), do: simple_shape!(queryable, opts)

    defp relationship_shape!(query, opts) do
      validate_boolean_operators!(query)
      validate_select!(query)

      sources = sources(query)
      edges = relationship_edges(query, sources)
      wheres = wheres_by_binding(query)
      root_wheres = Map.get(wheres, 0, [])

      root_query = %{query | joins: [], wheres: root_wheres}
      root_shape = simple_shape!(root_query, opts)
      relationship_where = relationship_where(0, edges, wheres, sources)

      %{root_shape | where: combine_where([root_shape.where, relationship_where])}
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

    defp validate_boolean_operators!(query) do
      if Enum.any?(query.wheres, &(&1.op != :and)) do
        raise ArgumentError,
          message:
            "Ecto OR across separate where clauses cannot be represented by relationship " <>
              "subqueries. Put same-table OR expressions in one where clause."
      end
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

        {parent_binding, parent_fields, child_fields} =
          relationship_fields!(join, child_binding, sources)

        %{
          parent: parent_binding,
          parent_fields:
            Enum.map(parent_fields, &field_source(sources[parent_binding].schema, &1)),
          child: child_binding,
          child_fields: Enum.map(child_fields, &field_source(sources[child_binding].schema, &1))
        }
      end)
    end

    defp relationship_fields!(
           %{assoc: {parent, association}, source: nil, on: %{expr: true}},
           _child_binding,
           sources
         ) do
      association = association!(sources[parent].schema, association, parent)
      {parent, [association.owner_key], [association.related_key]}
    end

    defp relationship_fields!(%{assoc: {_parent, _association}, source: nil}, binding, _sources) do
      raise ArgumentError,
        message:
          "Ecto association join binding #{binding} has an additional ON predicate. " <>
            "Put joined-table predicates in a where clause."
    end

    defp relationship_fields!(join, child_binding, _sources) do
      relationships =
        join.on.expr
        |> equality_fields!(child_binding)
        |> Enum.map(&orient_relationship!(&1, child_binding))

      case Enum.group_by(relationships, &elem(&1, 0)) |> Map.to_list() do
        [{parent_binding, relationships}] ->
          {parent_fields, child_fields} =
            Enum.map(relationships, fn {_parent_binding, parent_field, child_field} ->
              {parent_field, child_field}
            end)
            |> Enum.unzip()

          {parent_binding, parent_fields, child_fields}

        _relationships ->
          raise ArgumentError,
            message:
              "Ecto join binding #{child_binding} must equate its fields with fields from " <>
                "one earlier binding"
      end
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

    defp equality_fields!({:and, _, [left, right]}, binding) do
      equality_fields!(left, binding) ++ equality_fields!(right, binding)
    end

    defp equality_fields!(
           {:==, _, [left, right]} = expression,
           binding
         ) do
      with {:ok, {left_binding, left_field}} <- field_reference(left),
           {:ok, {right_binding, right_field}} <- field_reference(right) do
        [{left_binding, left_field, right_binding, right_field}]
      else
        _ ->
          raise ArgumentError,
            message:
              "Ecto join binding #{binding} must use field equalities joined with AND, got: " <>
                inspect(expression)
      end
    end

    defp equality_fields!(expression, binding) do
      raise ArgumentError,
        message:
          "Ecto join binding #{binding} must use field equalities joined with AND, got: " <>
            inspect(expression)
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

    defp relationship_where(parent, edges, wheres, sources) do
      edges
      |> Enum.filter(&(&1.parent == parent))
      |> Enum.map(fn edge ->
        child_where = source_where(edge.child, wheres, sources)
        nested_where = relationship_where(edge.child, edges, wheres, sources)
        where = combine_where([child_where, nested_where])
        source = sources[edge.child]

        [
          quote_field_tuple(edge.parent_fields),
          " IN (SELECT ",
          Enum.map_join(edge.child_fields, ", ", &quote_identifier/1),
          " FROM ",
          quote_table(source),
          if(where, do: [" WHERE ", where], else: []),
          ")"
        ]
        |> IO.iodata_to_binary()
      end)
      |> combine_where()
    end

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
