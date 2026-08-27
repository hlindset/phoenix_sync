defmodule Phoenix.Sync.ClientTest do
  use ExUnit.Case,
    async: false,
    parameterize: [
      %{
        sync_config: [
          env: :test,
          mode: :embedded,
          pool_opts: [backoff_type: :stop, max_restarts: 0, pool_size: 2]
        ]
      },
      %{
        sync_config: [
          env: :test,
          mode: :http,
          url: "http://localhost:3000",
          pool_opts: [backoff_type: :stop, max_restarts: 0, pool_size: 2]
        ]
      }
    ]

  alias Phoenix.Sync.Client
  alias Electric.Client.Message.ChangeMessage
  alias Electric.Client.Message.Headers
  alias Electric.Client.Message.ControlMessage

  import Support.DbSetup
  import Support.ElectricHelpers

  import Ecto.Query, only: [from: 2]

  Code.ensure_loaded!(Support.Todo)
  Code.ensure_loaded!(Support.Repo)

  @moduletag table: {
               "todos",
               [
                 "id int8 not null primary key generated always as identity",
                 "title text",
                 "completed boolean default false"
               ]
             }
  @moduletag data:
               {"todos", ["title", "completed"],
                [["one", false], ["two", false], ["three", true]]}

  defp assert_embedded_client(client) do
    assert %Electric.Client{fetch: {Electric.Client.Embedded, _}} = client
  end

  defp assert_http_client(client, endpoint) do
    endpoint = URI.new!(endpoint)
    assert %Electric.Client{endpoint: ^endpoint, fetch: {Electric.Client.Fetch.HTTP, _}} = client
  end

  defp is_mock_client?(%Electric.Client{fetch: {Electric.Client.Mock, _}}), do: true
  defp is_mock_client?(%Electric.Client{}), do: false

  setup [
    :with_stack_id_from_test,
    :with_unique_db,
    :with_stack_config,
    :with_table,
    :with_data,
    :with_relationship_tables,
    :start_embedded
  ]

  defp with_relationship_tables(%{relationship: true, db_conn: db_conn}) do
    Postgrex.query!(
      db_conn,
      "CREATE TABLE boards (id text PRIMARY KEY, active boolean NOT NULL)",
      []
    )

    Postgrex.query!(
      db_conn,
      "CREATE TABLE episodes (id text PRIMARY KEY, board_id text NOT NULL REFERENCES boards(id), title text NOT NULL)",
      []
    )

    Postgrex.query!(
      db_conn,
      "INSERT INTO boards (id, active) VALUES ('board-1', true), ('board-2', false)",
      []
    )

    Postgrex.query!(
      db_conn,
      "INSERT INTO episodes (id, board_id, title) VALUES ('episode-1', 'board-1', 'active episode'), ('episode-2', 'board-2', 'inactive episode')",
      []
    )

    :ok
  end

  defp with_relationship_tables(_ctx), do: :ok

  describe "client/1" do
    test "returns embedded client when configured" do
      config = [
        mode: :embedded
      ]

      assert {:ok, client} = Client.new(config)

      assert_embedded_client(client)
    end

    test "returns http client when configured" do
      config = [
        mode: :http,
        url: "http://api.electric-sql.cloud"
      ]

      assert {:ok, client} = Client.new(config)

      assert_http_client(client, "http://api.electric-sql.cloud/v1/shape")
    end

    test "passes credentials into client" do
      config = [
        mode: :http,
        url: "http://api.electric-sql.cloud",
        credentials: [
          secret: "my-secret",
          source_id: "my-source-id"
        ],
        params: %{
          something: "here"
        }
      ]

      assert {:ok, client} = Client.new(config)

      assert client.params == %{secret: "my-secret", source_id: "my-source-id", something: "here"}
    end
  end

  describe "stream" do
    setup(ctx) do
      {:ok, client: Client.new!(ctx.electric_opts)}
    end

    test "with schema module", ctx do
      stream = Phoenix.Sync.Client.stream(Support.Todo, client: ctx.client)

      events = Enum.take(stream, 4)

      assert [
               %ChangeMessage{
                 value: %Support.Todo{title: "one", completed: false},
                 headers: %Headers{operation: :insert}
               },
               %ChangeMessage{
                 value: %Support.Todo{title: "two", completed: false},
                 headers: %Headers{operation: :insert}
               },
               %ChangeMessage{
                 value: %Support.Todo{title: "three", completed: true},
                 headers: %Headers{operation: :insert}
               },
               %ControlMessage{control: :up_to_date}
             ] = events
    end

    test "with ecto query", ctx do
      stream =
        Phoenix.Sync.Client.stream(
          from(t in Support.Todo, where: t.completed == true),
          client: ctx.client
        )

      events = Enum.take(stream, 2)

      assert [
               %ChangeMessage{
                 value: %Support.Todo{title: "three", completed: true},
                 headers: %Headers{operation: :insert}
               },
               %ControlMessage{control: :up_to_date}
             ] = events
    end

    test "with ecto query and additional shape opts", ctx do
      stream =
        Phoenix.Sync.Client.stream(
          from(t in Support.Todo, where: t.completed == true),
          namespace: "app",
          replica: :full,
          live: false,
          errors: :stream,
          client: ctx.client
        )

      assert %Electric.Client.Stream{
               client: %{
                 params: %{
                   "columns" => "id,title,completed",
                   "replica" => "full",
                   "table" => "app.todos",
                   "where" => "(\"completed\" = TRUE)"
                 }
               },
               opts: %{errors: :stream, live: false}
             } = stream
    end

    test "with table name", ctx do
      stream =
        Phoenix.Sync.Client.stream("todos", client: ctx.client)

      events = Enum.take(stream, 4)

      assert [
               %ChangeMessage{
                 value: %{"title" => "one", "completed" => "false"},
                 headers: %Headers{operation: :insert}
               },
               %ChangeMessage{
                 value: %{"title" => "two", "completed" => "false"},
                 headers: %Headers{operation: :insert}
               },
               %ChangeMessage{
                 value: %{"title" => "three", "completed" => "true"},
                 headers: %Headers{operation: :insert}
               },
               %ControlMessage{control: :up_to_date}
             ] = events
    end

    test "allows for specifying a custom client", _ctx do
      {:ok, client} = Electric.Client.Mock.new()

      stream =
        Phoenix.Sync.Client.stream(
          table: "todos",
          where: "completed = true",
          client: client
        )

      assert is_mock_client?(stream.client)

      stream =
        Phoenix.Sync.Client.stream(
          "todos",
          where: "completed = true",
          client: client
        )

      assert is_mock_client?(stream.client)
    end

    test "with shape params", ctx do
      stream =
        Phoenix.Sync.Client.stream(
          table: "todos",
          namespace: "public",
          where: "completed = true",
          columns: ["id", "title"],
          client: ctx.client
        )

      events = Enum.take(stream, 2)

      assert [
               %ChangeMessage{
                 value: %{"title" => "three"},
                 headers: %Headers{operation: :insert}
               },
               %ControlMessage{control: :up_to_date}
             ] = events
    end

    test "materializes relationship move-outs as deletes" do
      {:ok, client} = Electric.Client.Mock.new()

      stream_task =
        Task.async(fn ->
          Phoenix.Sync.Client.stream(
            table: "episodes",
            where: "board_id IN (SELECT id FROM boards WHERE active = true)",
            client: client
          )
          |> Enum.take(3)
        end)

      key = ~s|"public"."episodes"/"episode-1"|
      value = %{"id" => "episode-1", "board_id" => "board-1", "title" => "Pilot"}

      {:ok, _request} =
        Electric.Client.Mock.response(client,
          status: 200,
          schema: %{
            id: %{type: "text", pk_position: 0},
            board_id: %{type: "text"},
            title: %{type: "text"}
          },
          last_offset: Electric.Client.Offset.first(),
          shape_handle: "episodes-1",
          body: [
            %{
              "key" => key,
              "value" => value,
              "headers" => %{
                "operation" => "insert",
                "tags" => ["active-board"],
                "active_conditions" => [true]
              }
            },
            Electric.Client.Mock.up_to_date()
          ]
        )

      {:ok, _request} =
        Electric.Client.Mock.response(client,
          status: 200,
          last_offset: Electric.Client.Offset.new(1, 0),
          shape_handle: "episodes-1",
          body: [
            %{
              "headers" => %{
                "event" => "move-out",
                "patterns" => [%{"pos" => 0, "value" => "active-board"}]
              }
            }
          ]
        )

      assert [
               %ChangeMessage{key: ^key, value: ^value, headers: %Headers{operation: :insert}},
               %ControlMessage{control: :up_to_date},
               %ChangeMessage{key: ^key, value: ^value, headers: %Headers{operation: :delete}}
             ] = Task.await(stream_task)
    end

    @tag relationship: true
    @tag electric_storage: :persistent
    @tag long_poll_timeout: 5_000
    @tag :tmp_dir
    @tag timeout: 30_000
    test "materializes database-backed relationship membership changes", ctx do
      test_pid = self()

      stream_task =
        Task.async(fn ->
          Phoenix.Sync.Client.stream(
            table: "episodes",
            where: "board_id IN (SELECT id FROM boards WHERE active = true)",
            replica: :full,
            client: ctx.client
          )
          |> Enum.each(&send(test_pid, {:relationship_event, &1}))
        end)

      active_key = ~s|"public"."episodes"/"episode-1"|
      inactive_key = ~s|"public"."episodes"/"episode-2"|

      active_episode = %{
        "id" => "episode-1",
        "board_id" => "board-1",
        "title" => "active episode"
      }

      inactive_episode = %{
        "id" => "episode-2",
        "board_id" => "board-2",
        "title" => "inactive episode"
      }

      assert_receive {:relationship_event,
                      %ChangeMessage{
                        key: ^active_key,
                        value: ^active_episode,
                        headers: %Headers{operation: :insert}
                      }},
                     5_000

      assert_receive {:relationship_event, %ControlMessage{control: :up_to_date}}, 5_000

      Postgrex.query!(
        ctx.db_conn,
        "UPDATE boards SET active = false WHERE id = 'board-1'",
        []
      )

      assert_receive {:relationship_event,
                      %ChangeMessage{
                        key: ^active_key,
                        value: ^active_episode,
                        headers: %Headers{operation: :delete}
                      }},
                     5_000

      assert_receive {:relationship_event, %ControlMessage{control: :up_to_date}}, 5_000

      Postgrex.query!(
        ctx.db_conn,
        "UPDATE boards SET active = true WHERE id = 'board-2'",
        []
      )

      assert_receive {:relationship_event,
                      %ChangeMessage{
                        key: ^inactive_key,
                        value: ^inactive_episode,
                        headers: %Headers{operation: :insert}
                      }},
                     5_000

      Task.shutdown(stream_task, :brutal_kill)
    end
  end
end
