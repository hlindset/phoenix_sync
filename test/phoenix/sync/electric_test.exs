defmodule Phoenix.Sync.ElectricTest do
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

  use Support.ElectricHelpers, endpoint: __MODULE__.Endpoint

  import Plug.Test
  import Mox

  require Phoenix.ConnTest

  defmodule Router do
    use Phoenix.Router

    pipeline :browser do
      plug :accepts, ["html"]
    end

    scope "/api" do
      pipe_through [:browser]

      forward "/", Phoenix.Sync.Electric
    end
  end

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :phoenix_sync

    plug Router
  end

  Code.ensure_loaded!(Support.Todo)
  Code.ensure_loaded!(Support.Repo)

  defmodule MyEnv do
    def client!(opts \\ []) do
      Electric.Client.new!(
        base_url: "https://cloud.electric-sql.com",
        authenticator:
          Keyword.get(
            opts,
            :authenticator,
            {Electric.Client.Authenticator.MockAuthenticator, salt: "my-salt"}
          )
      )
    end

    def authenticate(conn, shape, opts \\ [])

    def authenticate(%Plug.Conn{} = conn, %Electric.Client.ShapeDefinition{} = shape, opts) do
      mode = Keyword.get(opts, :mode, :fun)

      %{
        "shape-auth-mode" => to_string(mode),
        "shape-auth-path" => conn.request_path,
        "shape-auth-table" => shape.table
      }
    end
  end

  setup :verify_on_exit!

  setup [
    :define_endpoint,
    :with_stack_id_from_test,
    :with_unique_db,
    :with_stack_config,
    :with_table,
    :with_data,
    :start_embedded,
    :configure_endpoint
  ]

  test "transforms subset data without changing response metadata", _ctx do
    response = %{
      "metadata" => %{"columns" => [%{"name" => "value", "type" => "text"}]},
      "data" => [
        %{
          "key" => "things/1",
          "headers" => %{"operation" => "insert"},
          "value" => %{"value" => "one"}
        }
      ],
      "future-field" => %{"preserved" => true}
    }

    mapper = fn message ->
      [put_in(message, ["value", "mapped"], String.upcase(message["value"]["value"]))]
    end

    assert %{
             "metadata" => %{
               "columns" => [%{"name" => "value", "type" => "text"}]
             },
             "data" => [%{"value" => %{"value" => "one", "mapped" => "ONE"}}],
             "future-field" => %{"preserved" => true}
           } = Phoenix.Sync.Electric.map_response_body(response, mapper)
  end

  defmodule MyEnv.TestRouter do
    use Plug.Router, copy_opts_to_assign: :config
    use Phoenix.Sync.Electric

    plug :match
    plug :dispatch

    forward "/shapes",
      to: Phoenix.Sync.Electric,
      init_opts: [opts_in_assign: :config]

    forward "/v1/shape",
      to: Phoenix.Sync.Electric,
      init_opts: [opts_in_assign: :config]
  end

  defmodule HttpProxyRouter do
    use Plug.Router, copy_opts_to_assign: :config
    use Phoenix.Sync.Router, opts_in_assign: :config

    plug :match
    plug :dispatch

    sync "/things",
      table: "things",
      queryable_columns: ["id", "value"],
      log: :changes_only
  end

  defmodule HttpProxyPlug do
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      conn = HttpProxyRouter.call(conn, opts)

      send(
        Keyword.fetch!(opts, :test_pid),
        {:proxy_request_finished, conn.request_path,
         URI.decode_query(conn.query_string)["live_sse"]}
      )

      conn
    end
  end

  defp call(conn, plug \\ MyEnv.TestRouter, ctx) do
    opts = Phoenix.Sync.plug_opts(electric_opts(ctx))

    plug.call(conn, phoenix_sync: opts)
  end

  defp start_bandit(ctx) do
    plug_opts = [phoenix_sync: Phoenix.Sync.plug_opts(electric_opts(ctx))]

    pid =
      start_supervised!(
        {Bandit, plug: {MyEnv.TestRouter, plug_opts}, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  defp start_http_proxy(ctx, upstream_url) do
    electric_opts =
      ctx.electric_opts
      |> Keyword.put(:mode, :http)
      |> Keyword.put(:url, upstream_url)

    plug_opts = [phoenix_sync: Phoenix.Sync.plug_opts(electric_opts), test_pid: self()]

    pid =
      start_supervised!({Bandit, plug: {HttpProxyPlug, plug_opts}, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  describe "Plug" do
    @describetag table: {
                   "things",
                   ["id int8 not null primary key generated always as identity", "value text"]
                 }
    @describetag data: {"things", ["value"], [["one"], ["two"], ["three"]]}

    test "provides the standard electric http api", ctx do
      resp =
        conn(:get, "/shapes", %{"table" => "things", "offset" => "-1"})
        |> call(ctx)

      assert resp.status == 200
      assert Plug.Conn.get_resp_header(resp, "electric-offset") == ["0_0"]

      assert [
               %{"headers" => %{"operation" => "insert"}, "value" => %{"value" => "one"}},
               %{"headers" => %{"operation" => "insert"}, "value" => %{"value" => "two"}},
               %{"headers" => %{"operation" => "insert"}, "value" => %{"value" => "three"}},
               %{"headers" => %{"control" => "snapshot-end"}}
             ] = Jason.decode!(resp.resp_body)
    end

    @tag long_poll_timeout: 5_000
    test "activates changes-only shapes before returning offset=now", ctx do
      initial =
        conn(:get, "/shapes", %{
          "table" => "things",
          "offset" => "now",
          "log" => "changes_only"
        })
        |> call(ctx)

      assert initial.status == 200
      assert [handle] = Plug.Conn.get_resp_header(initial, "electric-handle")
      assert [offset] = Plug.Conn.get_resp_header(initial, "electric-offset")

      Postgrex.query!(ctx.db_conn, "INSERT INTO things (value) VALUES ('four')", [])

      changes =
        conn(:get, "/shapes", %{
          "table" => "things",
          "offset" => offset,
          "handle" => handle,
          "live" => "true",
          "log" => "changes_only"
        })
        |> call(ctx)

      assert changes.status == 200

      assert [
               %{
                 "headers" => %{"operation" => "insert"},
                 "value" => %{"value" => "four"}
               }
               | _controls
             ] = Jason.decode!(changes.resp_body)
    end

    test "makes mounted shape responses eligible for compression", ctx do
      resp =
        conn(:get, "/shapes", %{"table" => "things", "offset" => "-1"})
        |> Plug.Conn.put_req_header("accept-encoding", "gzip")
        |> call(ctx)

      assert resp.status == 200
      assert resp.state == :sent
      assert ["W/" <> _etag] = Plug.Conn.get_resp_header(resp, "etag")

      assert resp
             |> Plug.Conn.get_resp_header("vary")
             |> Enum.flat_map(&Plug.Conn.Utils.list/1)
             |> Enum.any?(&(String.downcase(&1, :ascii) == "accept-encoding"))

      assert [%{"value" => %{"value" => "one"}} | _rest] = Jason.decode!(resp.resp_body)
    end

    test "does not buffer when response encodings are declined", ctx do
      resp =
        conn(:get, "/shapes", %{"table" => "things", "offset" => "-1"})
        |> Plug.Conn.put_req_header("accept-encoding", "gzip;q=0")
        |> call(ctx)

      assert [etag] = Plug.Conn.get_resp_header(resp, "etag")
      refute String.starts_with?(etag, "W/")
    end

    test "supports DELETEs", ctx do
      resp =
        conn(:get, "/shapes", %{"table" => "things", "offset" => "-1"})
        |> call(ctx)

      assert resp.status == 200
      [handle] = Plug.Conn.get_resp_header(resp, "electric-handle")

      resp =
        conn(:delete, "/shapes?handle=#{handle}")
        |> call(ctx)

      # api is not configured to allow deletes
      assert resp.status == 405

      resp =
        conn(:delete, "/shapes?handle=#{handle}")
        |> call(Map.put(ctx, :allow_shape_deletion, true))

      assert resp.status == 202
    end

    test "supports OPTIONS", ctx do
      resp =
        conn(:options, "/shapes", %{"table" => "things", "offset" => "-1"})
        |> Plug.Conn.put_req_header("access-control-request-headers", "if-none-match")
        |> call(ctx)

      assert resp.status == 204

      assert ["if-none-match"] = Plug.Conn.get_resp_header(resp, "access-control-allow-headers")
    end
  end

  describe "Bandit" do
    @describetag table: {
                   "things",
                   ["id int8 not null primary key generated always as identity", "value text"]
                 }
    @describetag data: {"things", ["value"], [["one"], ["two"], ["three"]]}

    test "serves compressed shape responses over a real HTTP connection", ctx do
      response =
        Req.get!(start_bandit(ctx) <> "/shapes",
          params: [table: "things", offset: "-1"],
          headers: [{"accept-encoding", "gzip"}],
          raw: true
        )

      assert response.status == 200
      assert Req.Response.get_header(response, "content-encoding") == ["gzip"]
      assert Req.Response.get_header(response, "electric-offset") == ["0_0"]
      assert ["W/" <> _etag] = Req.Response.get_header(response, "etag")

      assert [
               %{"headers" => %{"operation" => "insert"}, "value" => %{"value" => "one"}},
               %{"headers" => %{"operation" => "insert"}, "value" => %{"value" => "two"}},
               %{"headers" => %{"operation" => "insert"}, "value" => %{"value" => "three"}},
               %{"headers" => %{"control" => "snapshot-end"}}
             ] = response.body |> :zlib.gunzip() |> Jason.decode!()
    end

    test "proxies POST subsets and live SSE over real HTTP connections", ctx do
      upstream_url = start_bandit(ctx)
      proxy_url = start_http_proxy(ctx, upstream_url)

      subset =
        Req.post!(proxy_url <> "/things",
          params: [offset: "now"],
          json: %{order_by: "id DESC", limit: 1},
          raw: true
        )

      assert subset.status == 200
      assert [_handle] = Req.Response.get_header(subset, "electric-handle")
      assert [_offset] = Req.Response.get_header(subset, "electric-offset")

      assert ["application/json; charset=utf-8"] =
               Req.Response.get_header(subset, "content-type")

      assert %{"data" => [%{"value" => %{"value" => "three"}}]} =
               Jason.decode!(subset.body)

      initial =
        Req.get!(proxy_url <> "/things",
          params: [offset: "now"],
          raw: true
        )

      assert [handle] = Req.Response.get_header(initial, "electric-handle")
      assert [offset] = Req.Response.get_header(initial, "electric-offset")

      Postgrex.query!(ctx.db_conn, "INSERT INTO things (value) VALUES ('four')", [])

      request =
        Req.new(
          url: proxy_url <> "/things",
          params: [offset: offset, handle: handle, live: "true", live_sse: "true"],
          raw: true,
          retry: false,
          receive_timeout: 5_000
        )

      assert {:ok, response, body} =
               Req.stream(request, "", fn data, _response, body ->
                 body = body <> data

                 case String.contains?(body, ~s|"value":"four"|) do
                   true -> {:halt, body}
                   false -> {:cont, body}
                 end
               end)

      assert response.status == 200
      assert ["text/event-stream"] = Req.Response.get_header(response, "content-type")
      assert [_offset] = Req.Response.get_header(response, "electric-offset")
      assert body =~ "data: "
      assert body =~ ~s|"operation":"insert"|
      assert body =~ ~s|"value":"four"|

      Postgrex.query!(ctx.db_conn, "INSERT INTO things (value) VALUES ('five')", [])

      assert_receive {:proxy_request_finished, "/things", "true"}, 5_000
    end
  end

  describe "Phoenix" do
    @describetag table: {
                   "things",
                   ["id int8 not null primary key generated always as identity", "value text"]
                 }
    @describetag data: {"things", ["value"], [["one"], ["two"], ["three"]]}

    test "provides the full shape api", _ctx do
      resp =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.get("/api", %{table: "things", offset: "-1"})

      assert resp.status == 200
      assert Plug.Conn.get_resp_header(resp, "electric-offset") == ["0_0"]

      assert [
               %{"headers" => %{"operation" => "insert"}, "value" => %{"value" => "one"}},
               %{"headers" => %{"operation" => "insert"}, "value" => %{"value" => "two"}},
               %{"headers" => %{"operation" => "insert"}, "value" => %{"value" => "three"}},
               %{"headers" => %{"control" => "snapshot-end"}}
             ] = Jason.decode!(resp.resp_body)
    end

    test "supports deletes", _ctx do
      resp =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.get("/api", %{table: "things", offset: "-1"})

      assert resp.status == 200
      assert [handle] = Plug.Conn.get_resp_header(resp, "electric-handle")

      resp =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.delete("/api", %{handle: handle})

      # method not allowed -- specific to the delete plug...
      assert resp.status == 405
    end
  end
end
