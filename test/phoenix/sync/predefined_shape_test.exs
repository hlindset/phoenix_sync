defmodule Phoenix.Sync.PredefinedShapeTest do
  use ExUnit.Case, async: true

  alias Phoenix.Sync.PredefinedShape
  alias Electric.Client.ShapeDefinition

  defmodule Cow do
    use Ecto.Schema

    schema "cows" do
      field :name, :string
      field :age, :integer
      field :breed, Ecto.Enum, values: [:holstein, :angus, :hereford, :jersey]
    end

    def changeset(data \\ %__MODULE__{}, params) do
      import Ecto.Changeset

      data
      |> cast(params, [:name, :age, :breed])
      |> validate_number(:age, greater_than: 0)
      |> validate_required([:name, :breed])
    end
  end

  defmodule Board do
    use Ecto.Schema

    schema "boards" do
      field :active, :boolean
      field :tenant_id, :integer

      has_many :published_episodes, Phoenix.Sync.PredefinedShapeTest.Episode,
        foreign_key: :board_id,
        where: [published: true]

      many_to_many :memberships, Phoenix.Sync.PredefinedShapeTest.Membership,
        join_through: "board_membership_links",
        join_keys: [board_id: :id, membership_id: :id]
    end
  end

  defmodule Episode do
    use Ecto.Schema

    schema "episodes" do
      field :board_id, :integer
      field :published, :boolean
      field :tenant_id, :integer
      field :title, :string
      belongs_to :board, Board, define_field: false

      belongs_to :active_board, Board,
        define_field: false,
        foreign_key: :board_id,
        where: [active: true]
    end
  end

  defmodule Membership do
    use Ecto.Schema

    schema "board_memberships" do
      field :board_id, :integer
      field :tenant_id, :integer
      field :user_id, :string
      field :role, Ecto.Enum, values: [:viewer, :editor]
    end
  end

  defmodule CompositeMembership do
    use Ecto.Schema

    @primary_key false
    schema "composite_memberships" do
      field :board_id, :integer, primary_key: true
      field :tenant_id, :integer, primary_key: true
      field :user_id, :string
    end
  end

  describe "new!/2" do
    test "raises if passed unknown options" do
      assert_raise ArgumentError, fn ->
        PredefinedShape.new!(table: "here", sheep: "baa")
      end
    end

    test "raises if passed invalid options" do
      invalid = [
        [],
        [where: "something = true"],
        [table: "here", replica: :invalid],
        [table: "here", storage: :invalid],
        [table: "here", params: :invalid],
        [table: "here", columns: :invalid],
        [table: "here", namespace: :invalid],
        [table: "here", where: :invalid],
        [table: "here", log: :invalid],
        [table: "here", queryable_columns: []],
        [table: "here", queryable_columns: "id"],
        [table: "here", queryable_columns: [1]],
        [table: "here", live: :invalid],
        [table: "here", errors: :invalid]
      ]

      for opts <- invalid do
        assert_raise NimbleOptions.ValidationError, fn ->
          PredefinedShape.new!(opts)
        end
      end
    end

    test "accepts keyword-based shape definition" do
      ps =
        PredefinedShape.new!(
          table: "todos",
          namespace: "test",
          where: "completed = $1",
          params: [true],
          replica: :full,
          columns: ["id", "title"],
          storage: %{compaction: :disabled}
        )

      assert PredefinedShape.to_client_params(ps) == %{
               "params[1]" => "true",
               "replica" => "full",
               "table" => "test.todos",
               "where" => "completed = $1",
               "columns" => "id,title"
             }

      assert PredefinedShape.to_api_params(ps) |> Enum.sort() ==
               Enum.sort(
                 table: "todos",
                 namespace: "test",
                 where: "completed = $1",
                 params: %{"1" => "true"},
                 replica: :full,
                 columns: ["id", "title"],
                 storage: %{compaction: :disabled}
               )
    end

    test "converts changes-only log mode for HTTP and embedded APIs" do
      ps = PredefinedShape.new!(table: "todos", log: :changes_only)

      assert PredefinedShape.to_client_params(ps) == %{
               "log" => "changes_only",
               "table" => "todos"
             }

      assert PredefinedShape.to_api_params(ps) |> Enum.sort() ==
               Enum.sort(table: "todos", log_mode: :changes_only)

      assert PredefinedShape.to_shape_params(ps) |> Enum.sort() ==
               Enum.sort(table: "todos", log_mode: :changes_only)
    end

    test "converts queryable columns for HTTP and embedded APIs" do
      ps =
        PredefinedShape.new!(
          table: "todos",
          queryable_columns: ["id", "completed"]
        )

      assert PredefinedShape.to_client_params(ps) == %{
               "queryable_columns" => "id,completed",
               "table" => "todos"
             }

      assert PredefinedShape.to_api_params(ps) |> Enum.sort() ==
               Enum.sort(table: "todos", queryable_columns: ["id", "completed"])

      assert PredefinedShape.to_shape_params(ps) |> Enum.sort() ==
               Enum.sort(table: "todos", queryable_columns: ["id", "completed"])
    end

    test "accepts Ecto schema" do
      ps = PredefinedShape.new!(Cow, storage: %{compaction: :disabled})

      assert PredefinedShape.to_client_params(ps) == %{
               "columns" => "id,name,age,breed",
               "table" => "cows"
             }

      assert PredefinedShape.to_api_params(ps) |> Enum.sort() ==
               Enum.sort(
                 table: "cows",
                 columns: ["id", "name", "age", "breed"],
                 storage: %{compaction: :disabled}
               )
    end

    test "accepts Ecto schema plus opts" do
      ps =
        PredefinedShape.new!(
          Cow,
          namespace: "test",
          where: "completed = $1",
          params: [true],
          replica: :full,
          columns: ["id", "title"],
          storage: %{compaction: :disabled}
        )

      assert PredefinedShape.to_client_params(ps) == %{
               "columns" => "id,title",
               "params[1]" => "true",
               "replica" => "full",
               "table" => "test.cows",
               "where" => "completed = $1"
             }
    end

    test "casts string-backed Ecto.Enum predicates to text" do
      import Ecto.Query

      query = from(cow in Cow, where: cow.breed in [:holstein, :angus])
      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where == ~s|(("breed"::text) IN ('holstein','angus'))|
    end

    test "does not rewrite enum column names inside string literals" do
      import Ecto.Query

      query = from(cow in Cow, where: cow.breed == :holstein and cow.name == ^~s|"breed"|)
      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where =~ ~s|("breed"::text)|
      assert shape.where =~ ~s|'"breed"'|
    end

    test "converts Ecto type/2 to an Electric-compatible cast" do
      import Ecto.Query

      query = from(cow in Cow, where: type(cow.age, :string) == "7")
      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where == ~s|(("age"::text) = '7')|

      assert {:ok, _expression} =
               Electric.Replication.Eval.Parser.parse_and_validate_expression(shape.where,
                 refs: %{["age"] => :int8}
               )
    end

    test "converts field-typed string parameters to Electric text casts" do
      import Ecto.Query

      name = "Daisy"
      query = from(cow in Cow, where: type(^name, cow.name) == cow.name)
      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where == ~s|(('Daisy'::text) = "name")|

      assert {:ok, _expression} =
               Electric.Replication.Eval.Parser.parse_and_validate_expression(shape.where,
                 refs: %{
                   ["name"] => :text
                 }
               )
    end

    test "preserves Electric-supported deterministic Ecto functions" do
      import Ecto.Query

      query = from(cow in Cow, where: coalesce(cow.name, "unknown") == "Daisy")
      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where == ~s|(coalesce("name", 'unknown') = 'Daisy')|

      assert {:ok, _expression} =
               Electric.Replication.Eval.Parser.parse_and_validate_expression(shape.where,
                 refs: %{
                   ["name"] => :text
                 }
               )
    end

    test "normalizes Electric-compatible casts on joined bindings" do
      import Ecto.Query

      query =
        from episode in Episode,
          join: board in Board,
          on: episode.board_id == board.id,
          where: type(board.tenant_id, :string) == "7",
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where ==
               ~s|"board_id" IN (SELECT "id" FROM "boards" WHERE (("tenant_id"::text) = '7'))|
    end

    test "reports keyword fragments with their Ecto binding" do
      import Ecto.Query

      query = from(cow in Cow, where: fragment(name: ["$eq": "Daisy"]))

      assert_raise ArgumentError,
                   ~r/Ecto filter on binding 0 uses a keyword or interpolated fragment/,
                   fn ->
                     query |> PredefinedShape.new!() |> PredefinedShape.to_shape()
                   end
    end

    test "converts inner equi-joins into relationship subqueries" do
      import Ecto.Query

      query =
        from episode in Episode,
          join: board in Board,
          on: episode.board_id == board.id,
          join: membership in Membership,
          on: board.id == membership.board_id,
          where: episode.published == true,
          where: board.active == true,
          where: membership.user_id == ^"user-1",
          where: membership.role == :editor,
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.table == "episodes"
      assert shape.columns == ["id", "board_id", "published", "tenant_id", "title"]
      assert shape.where =~ ~s|("published" = TRUE)|

      assert shape.where =~
               ~s|"board_id" IN (SELECT "id" FROM "boards" WHERE|

      assert shape.where =~ ~s|("active" = TRUE)|

      assert shape.where =~
               ~s|"id" IN (SELECT "board_id" FROM "board_memberships" WHERE|

      assert shape.where =~ ~s|("user_id" = 'user-1')|
      assert shape.where =~ ~s|(("role"::text) = 'editor')|
    end

    test "converts composite inner equi-joins into row relationship subqueries" do
      import Ecto.Query

      query =
        from episode in Episode,
          join: board in Board,
          on:
            episode.board_id == board.id and
              episode.tenant_id == board.tenant_id,
          where: board.active == true,
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where ==
               ~s|("board_id", "tenant_id") IN (SELECT "id", "tenant_id" FROM "boards" WHERE ("active" = TRUE))|
    end

    test "pushes joined-binding ON filters into relationship subqueries" do
      import Ecto.Query

      active = true

      query =
        from episode in Episode,
          join: board in Board,
          on:
            episode.board_id == board.id and
              episode.tenant_id == board.tenant_id and
              board.active == ^active,
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where ==
               ~s|("board_id", "tenant_id") IN (SELECT "id", "tenant_id" FROM "boards" WHERE ("active" = TRUE))|
    end

    test "converts Ecto IN subqueries into Electric relationship subqueries" do
      import Ecto.Query

      published = true

      memberships =
        from membership in Membership,
          where: membership.user_id == ^"user-1",
          select: membership.board_id

      query =
        from episode in Episode,
          where: episode.published == ^published and episode.board_id in subquery(memberships),
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where =~ ~s|("published" = TRUE)|

      assert shape.where =~
               ~s|"board_id" IN (SELECT "board_id" FROM "board_memberships" WHERE ("user_id" = 'user-1'))|
    end

    test "converts row-valued Ecto IN subqueries" do
      import Ecto.Query

      memberships =
        from membership in Membership,
          where: membership.user_id == ^"user-1",
          select: {membership.board_id, membership.tenant_id}

      query =
        from episode in Episode,
          where: fragment("(?, ?)", episode.board_id, episode.tenant_id) in subquery(memberships),
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where ==
               ~s|("board_id", "tenant_id") IN (SELECT "board_id", "tenant_id" FROM "board_memberships" WHERE ("user_id" = 'user-1'))|
    end

    test "converts plain-field map projections in Ecto IN subqueries" do
      import Ecto.Query

      memberships =
        from membership in Membership,
          where: membership.user_id == ^"user-1",
          select: %{board: membership.board_id, tenant: membership.tenant_id}

      query =
        from episode in Episode,
          where: fragment("(?, ?)", episode.board_id, episode.tenant_id) in subquery(memberships),
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where ==
               ~s|("board_id", "tenant_id") IN (SELECT "board_id", "tenant_id" FROM "board_memberships" WHERE ("user_id" = 'user-1'))|
    end

    test "converts Ecto map/2 projections in IN subqueries" do
      import Ecto.Query

      memberships =
        from membership in Membership,
          where: membership.user_id == ^"user-1",
          select: map(membership, [:board_id, :tenant_id])

      query =
        from episode in Episode,
          where: fragment("(?, ?)", episode.board_id, episode.tenant_id) in subquery(memberships),
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where ==
               ~s|("board_id", "tenant_id") IN (SELECT "board_id", "tenant_id" FROM "board_memberships" WHERE ("user_id" = 'user-1'))|
    end

    test "reports the computed entry in a subquery map projection" do
      import Ecto.Query

      memberships =
        from membership in Membership,
          select: %{board: membership.board_id + 1}

      query =
        from episode in Episode,
          where: episode.board_id in subquery(memberships),
          select: episode

      assert_raise ArgumentError,
                   ~r/map projection key :board must select a plain source field/,
                   fn ->
                     query |> PredefinedShape.new!() |> PredefinedShape.to_shape()
                   end
    end

    test "converts nested Ecto IN subqueries" do
      import Ecto.Query

      active_boards =
        from board in Board,
          where: board.active == true,
          select: board.id

      memberships =
        from membership in Membership,
          where:
            membership.user_id == ^"user-1" and
              membership.board_id in subquery(active_boards),
          select: membership.board_id

      query =
        from episode in Episode,
          where: episode.board_id in subquery(memberships),
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where =~
               ~s|"board_id" IN (SELECT "board_id" FROM "board_memberships" WHERE|

      assert shape.where =~
               ~s|"board_id" IN (SELECT "id" FROM "boards" WHERE ("active" = TRUE))|
    end

    test "rejects correlated Ecto subqueries" do
      import Ecto.Query

      memberships =
        from membership in Membership,
          where: membership.board_id == parent_as(:episode).board_id,
          select: membership.board_id

      query =
        from episode in Episode,
          as: :episode,
          where: episode.board_id in subquery(memberships),
          select: episode

      assert_raise ArgumentError, ~r/correlated Ecto subqueries/, fn ->
        query |> PredefinedShape.new!() |> PredefinedShape.to_shape()
      end
    end

    test "rejects negative Ecto subquery membership" do
      import Ecto.Query

      memberships = from membership in Membership, select: membership.board_id

      query =
        from episode in Episode,
          where: episode.board_id not in subquery(memberships),
          select: episode

      assert_raise ArgumentError, ~r/Negative Ecto subquery membership/, fn ->
        query |> PredefinedShape.new!() |> PredefinedShape.to_shape()
      end
    end

    test "converts negative Ecto subquery membership over non-null primary keys" do
      import Ecto.Query

      memberships =
        from membership in Membership,
          where: membership.user_id == ^"blocked",
          select: membership.id

      query =
        from episode in Episode,
          where: episode.id not in subquery(memberships),
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where ==
               ~s|"id" NOT IN (SELECT "id" FROM "board_memberships" WHERE ("user_id" = 'blocked'))|
    end

    test "converts row-valued negative membership over composite primary keys" do
      import Ecto.Query

      memberships =
        from membership in CompositeMembership,
          where: membership.user_id == ^"blocked",
          select: {membership.board_id, membership.tenant_id}

      query =
        from episode in Episode,
          where:
            fragment("(?, ?)", episode.board_id, episode.tenant_id) not in subquery(memberships),
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where ==
               ~s|("board_id", "tenant_id") NOT IN (SELECT "board_id", "tenant_id" FROM "composite_memberships" WHERE ("user_id" = 'blocked'))|
    end

    test "rejects subquery membership wrapped in another expression" do
      import Ecto.Query

      memberships = from membership in Membership, select: membership.board_id

      query =
        from episode in Episode,
          where: episode.board_id in subquery(memberships) == true,
          select: episode

      assert_raise ArgumentError, ~r/direct positive IN predicate/, fn ->
        query |> PredefinedShape.new!() |> PredefinedShape.to_shape()
      end
    end

    test "reports a missing subquery index in a manually constructed query" do
      import Ecto.Query

      memberships = from membership in Membership, select: membership.board_id

      query =
        from episode in Episode,
          where: episode.board_id in subquery(memberships),
          select: episode

      [where] = query.wheres
      {:in, meta, [left, {:subquery, 0}]} = where.expr
      query = %{query | wheres: [%{where | expr: {:in, meta, [left, {:subquery, 9}]}}]}

      assert_raise ArgumentError, ~r/references missing Ecto subquery index 9/, fn ->
        query |> PredefinedShape.new!() |> PredefinedShape.to_shape()
      end
    end

    test "reports a missing binding in a manually constructed membership predicate" do
      import Ecto.Query

      memberships = from membership in Membership, select: membership.board_id

      query =
        from episode in Episode,
          where: episode.board_id in subquery(memberships),
          select: episode

      [where] = query.wheres
      {:in, meta, [_left, subquery]} = where.expr
      missing_field = {{:., [], [{:&, [], [9]}, :board_id]}, [], []}
      query = %{query | wheres: [%{where | expr: {:in, meta, [missing_field, subquery]}}]}

      assert_raise ArgumentError, ~r/references missing Ecto binding 9/, fn ->
        query |> PredefinedShape.new!() |> PredefinedShape.to_shape()
      end
    end

    test "rejects ordering and limits in Ecto shape subqueries" do
      import Ecto.Query

      memberships =
        from membership in Membership,
          order_by: membership.board_id,
          limit: 1,
          select: membership.board_id

      query =
        from episode in Episode,
          where: episode.board_id in subquery(memberships),
          select: episode

      assert_raise ArgumentError, ~r/Ecto ORDER BY cannot be represented/, fn ->
        query |> PredefinedShape.new!() |> PredefinedShape.to_shape()
      end
    end

    test "converts Ecto association joins into relationship subqueries" do
      import Ecto.Query

      query =
        from episode in Episode,
          join: board in assoc(episode, :board),
          where: board.active == true,
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where ==
               ~s|"board_id" IN (SELECT "id" FROM "boards" WHERE ("active" = TRUE))|
    end

    test "preserves association metadata filters in relationship subqueries" do
      import Ecto.Query

      query =
        from episode in Episode,
          join: board in assoc(episode, :active_board),
          where: board.tenant_id in ^[1, 2],
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where =~
               ~s|"board_id" IN (SELECT "id" FROM "boards" WHERE|

      assert shape.where =~ ~s|("active" = TRUE)|
      assert shape.where =~ ~s|("tenant_id" IN (1,2))|
    end

    test "preserves has-many association metadata filters" do
      import Ecto.Query

      query =
        from board in Board,
          join: episode in assoc(board, :published_episodes),
          select: board

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where ==
               ~s|"id" IN (SELECT "board_id" FROM "episodes" WHERE ("published" = TRUE))|
    end

    test "reports unsupported many-to-many association joins" do
      import Ecto.Query

      query =
        from board in Board,
          join: membership in assoc(board, :memberships),
          select: board

      assert_raise ArgumentError, ~r/many-to-many association.*join table/, fn ->
        query |> PredefinedShape.new!() |> PredefinedShape.to_shape()
      end
    end

    test "preserves mixed-binding boolean expressions" do
      import Ecto.Query

      title = "mine"
      active = true
      blocked_user_id = "blocked"

      query =
        from episode in Episode,
          join: board in Board,
          on: episode.board_id == board.id,
          join: membership in Membership,
          on: board.id == membership.board_id,
          where:
            episode.title == ^title or
              (board.active == ^active and not (membership.user_id == ^blocked_user_id)),
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where =~ ~s|("title" = 'mine')|
      assert shape.where =~ ") OR ("
      assert shape.where =~ ~s|("active" = TRUE)|
      assert shape.where =~ ~s|NOT (|
      assert shape.where =~ ~s|("user_id" = 'blocked')|
    end

    test "preserves or_where across Ecto bindings" do
      import Ecto.Query

      query =
        from episode in Episode,
          join: board in Board,
          on: episode.board_id == board.id,
          where: episode.published == false,
          or_where: board.active == true,
          select: episode

      shape = query |> PredefinedShape.new!() |> PredefinedShape.to_shape()

      assert shape.where =~ ~s|("published" = FALSE)|
      assert shape.where =~ ~s| OR |
      assert shape.where =~ ~s|("active" = TRUE)|
    end

    test "rejects join predicates that compare data beyond the relationship key" do
      import Ecto.Query

      query =
        from episode in Episode,
          join: board in Board,
          on: episode.board_id == board.id,
          where: episode.published == board.active

      assert_raise ArgumentError, ~r/predicate references multiple Ecto bindings/, fn ->
        query |> PredefinedShape.new!() |> PredefinedShape.to_shape()
      end
    end

    test "rejects query operations that cannot remain correct as a live shape" do
      import Ecto.Query

      queries = [
        from(episode in Episode, order_by: episode.title),
        from(episode in Episode, limit: 10),
        from(episode in Episode, preload: [:board]),
        from(episode in Episode, group_by: episode.board_id, select: episode.board_id),
        from(episode in Episode, select: count(episode.id))
      ]

      for query <- queries do
        assert_raise ArgumentError, ~r/cannot be represented by an Electric shape/, fn ->
          query |> PredefinedShape.new!() |> PredefinedShape.to_shape()
        end
      end
    end

    test "changeset function plus opts" do
      ps =
        PredefinedShape.new!(
          &Cow.changeset/1,
          namespace: "test",
          where: "completed = $1",
          params: [true],
          replica: :full,
          storage: %{compaction: :disabled},
          live: false,
          errors: :stream
        )

      assert PredefinedShape.to_client_params(ps) == %{
               "columns" => "id,name,breed,age",
               "params[1]" => "true",
               "replica" => "full",
               "table" => "test.cows",
               "where" => "completed = $1"
             }

      assert {%{__struct__: ShapeDefinition}, [live: false, errors: :stream]} =
               PredefinedShape.to_stream_params(ps)
    end

    @tag :transform
    test "transform function is accepted as mfa" do
      ps =
        PredefinedShape.new!(
          Cow,
          namespace: "test",
          where: "completed = $1",
          params: [true],
          replica: :full,
          columns: ["id", "title"],
          transform: {__MODULE__, :map_cow_dupe, []},
          storage: %{compaction: :disabled}
        )

      assert fun = PredefinedShape.transform_fun(ps)
      assert is_function(fun, 1)

      assert [:msg, :msg] = fun.(:msg)
    end

    @tag :transform
    test "transform function is accepted as a capture" do
      ps =
        PredefinedShape.new!(
          Cow,
          namespace: "test",
          where: "completed = $1",
          params: [true],
          replica: :full,
          columns: ["id", "title"],
          transform: &map_cow/1,
          storage: %{compaction: :disabled}
        )

      assert fun = PredefinedShape.transform_fun(ps)
      assert is_function(fun, 1)

      assert [:msg] = fun.(:msg)
    end

    @tag :transform
    test "ecto schema modules are accepted as a transform argument" do
      ps =
        PredefinedShape.new!(
          Cow,
          namespace: "test",
          where: "completed = $1",
          params: [true],
          replica: :full,
          transform: Cow
        )

      assert fun = PredefinedShape.transform_fun(ps)
      assert is_function(fun, 1)

      assert [
               %{
                 "key" => "key",
                 "headers" => %{"operation" => "insert"},
                 "value" => %Cow{name: "Daisy", age: 12, breed: :jersey}
               }
             ] =
               fun.(%{
                 "key" => "key",
                 "headers" => %{"operation" => "insert"},
                 "value" => %{"name" => "Daisy", "age" => 12, "breed" => "jersey"}
               })
    end

    @tag :transform
    test "transform function is wrapped to return a list" do
      ps =
        PredefinedShape.new!(
          Cow,
          namespace: "test",
          where: "completed = $1",
          params: [true],
          replica: :full,
          columns: ["id", "title"],
          transform: {__MODULE__, :map_cow, []},
          storage: %{compaction: :disabled}
        )

      assert fun = PredefinedShape.transform_fun(ps)
      assert is_function(fun, 1)

      assert [:msg] = fun.(:msg)
    end

    @tag :transform
    test "shape with no transform fun" do
      ps = PredefinedShape.new!(table: "cows")

      assert nil == PredefinedShape.transform_fun(ps)
    end

    @tag :transform
    test "transform_fun accepts and returns nil" do
      assert nil == PredefinedShape.transform_fun(nil)
    end
  end

  def map_cow(msg), do: msg
  def map_cow_dupe(msg), do: [msg, msg]
end
