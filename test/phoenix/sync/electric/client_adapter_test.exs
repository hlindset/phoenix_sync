defmodule Phoenix.Sync.Electric.ClientAdapterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Phoenix.Sync.Electric.ClientAdapter
  alias Phoenix.Sync.PredefinedShape

  defmodule MockFetch do
    def validate_opts(opts), do: {:ok, opts}

    def fetch(request, opts) do
      parent = Keyword.fetch!(opts, :parent)
      send(parent, {:fetch_request, request})

      %Electric.Client.Fetch.Response{
        status: 200,
        headers: Keyword.get(opts, :response_headers, %{}),
        body: ["[]"]
      }
    end
  end

  test "forwards safe request headers without credentials or hop-by-hop headers" do
    {:ok, client} =
      Electric.Client.new(
        base_url: "elixir://#{inspect(__MODULE__.Fetch)}",
        fetch: {MockFetch, parent: self()}
      )

    adapter = %ClientAdapter{client: client}

    conn =
      conn(:get, "/v1/shapes", %{})
      |> Plug.Conn.put_req_header("my-header-1", "my-header-1-value-1")
      |> Plug.Conn.prepend_req_headers([{"my-header-1", "my-header-1-value-2"}])
      |> Plug.Conn.put_req_header("my-header-2", "my-header-2-value")
      |> Plug.Conn.put_req_header("authorization", "Bearer browser-credential")
      |> Plug.Conn.put_req_header("cookie", "session=browser-cookie")
      |> Plug.Conn.put_req_header("proxy-authenticate", "Basic realm=browser")
      |> Plug.Conn.put_req_header("proxy-authorization", "Basic proxy-credential")
      |> Plug.Conn.put_req_header("connection", "Keep-Alive, X-Private-Connection")
      |> Plug.Conn.prepend_req_headers([{"connection", "X-Second-Private"}])
      |> Plug.Conn.put_req_header("content-length", "123")
      |> Plug.Conn.put_req_header("keep-alive", "timeout=5")
      |> Plug.Conn.put_req_header("proxy-connection", "keep-alive")
      |> Plug.Conn.put_req_header("te", "trailers")
      |> Plug.Conn.put_req_header("trailer", "x-checksum")
      |> Plug.Conn.put_req_header("x-private-connection", "private")
      |> Plug.Conn.put_req_header("x-second-private", "also-private")
      |> Plug.Conn.put_req_header("transfer-encoding", "chunked")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> then(fn conn ->
        %{conn | req_headers: [{"host", "browser.example"} | conn.req_headers]}
      end)

    assert %{status: 200} = Phoenix.Sync.Adapter.PlugApi.call(adapter, conn, %{offset: -1})
    assert_receive {:fetch_request, request}

    assert request.headers == %{
             "my-header-1" => ["my-header-1-value-1", "my-header-1-value-2"],
             "my-header-2" => ["my-header-2-value"]
           }
  end

  test "returns safe upstream headers without cookies or hop-by-hop headers" do
    {:ok, client} =
      Electric.Client.new(
        base_url: "elixir://#{inspect(__MODULE__.Fetch)}",
        fetch:
          {MockFetch,
           parent: self(),
           response_headers: %{
             "cache-control" => ["public, max-age=5"],
             "electric-offset" => ["1_0"],
             "connection" => ["Keep-Alive, X-Private-Connection", "X-Second-Private"],
             "content-length" => ["123"],
             "keep-alive" => ["timeout=5"],
             "proxy-authenticate" => ["Basic realm=upstream"],
             "proxy-authorization" => ["Basic upstream-proxy-credential"],
             "proxy-connection" => ["keep-alive"],
             "x-private-connection" => ["private"],
             "x-second-private" => ["also-private"],
             "set-cookie" => ["electric_session=secret"],
             "set-cookie2" => ["electric_legacy_session=secret"],
             "te" => ["trailers"],
             "trailer" => ["x-checksum"],
             "transfer-encoding" => ["chunked"],
             "upgrade" => ["websocket"]
           }}
      )

    adapter = %ClientAdapter{client: client}

    response = Phoenix.Sync.Adapter.PlugApi.call(adapter, conn(:get, "/v1/shapes"), %{offset: -1})

    assert Plug.Conn.get_resp_header(response, "cache-control") == ["public, max-age=5"]
    assert Plug.Conn.get_resp_header(response, "electric-offset") == ["1_0"]
    assert Plug.Conn.get_resp_header(response, "connection") == []
    assert Plug.Conn.get_resp_header(response, "content-length") == []
    assert Plug.Conn.get_resp_header(response, "keep-alive") == []
    assert Plug.Conn.get_resp_header(response, "proxy-authenticate") == []
    assert Plug.Conn.get_resp_header(response, "proxy-authorization") == []
    assert Plug.Conn.get_resp_header(response, "proxy-connection") == []
    assert Plug.Conn.get_resp_header(response, "x-private-connection") == []
    assert Plug.Conn.get_resp_header(response, "x-second-private") == []
    assert Plug.Conn.get_resp_header(response, "set-cookie") == []
    assert Plug.Conn.get_resp_header(response, "set-cookie2") == []
    assert Plug.Conn.get_resp_header(response, "te") == []
    assert Plug.Conn.get_resp_header(response, "trailer") == []
    assert Plug.Conn.get_resp_header(response, "transfer-encoding") == []
    assert Plug.Conn.get_resp_header(response, "upgrade") == []
  end

  test "forwards subset parameters for server-defined shapes" do
    {:ok, client} =
      Electric.Client.new(
        base_url: "elixir://#{inspect(__MODULE__.Fetch)}",
        fetch: {MockFetch, parent: self()}
      )

    adapter = %ClientAdapter{client: client}
    shape = PredefinedShape.new!("things")

    assert {:ok, shape_adapter} =
             Phoenix.Sync.Adapter.PlugApi.predefined_shape(adapter, shape)

    params = %{
      "offset" => "-1",
      "subset__where" => "value = $1",
      "subset__params" => ["one"],
      "ignored" => "not-forwarded"
    }

    assert %{status: 200} =
             Phoenix.Sync.Adapter.PlugApi.call(shape_adapter, conn(:get, "/things"), params)

    assert_receive {:fetch_request, request}

    assert request.params["subset__where"] == "value = $1"
    assert request.params["subset__params"] == ["one"]
    refute Map.has_key?(request.params, "ignored")
  end

  test "forwards changes-only mode and offset=now for server-defined shapes" do
    {:ok, client} =
      Electric.Client.new(
        base_url: "elixir://#{inspect(__MODULE__.Fetch)}",
        fetch: {MockFetch, parent: self()}
      )

    adapter = %ClientAdapter{client: client}
    shape = PredefinedShape.new!("things", log: :changes_only)

    assert {:ok, shape_adapter} =
             Phoenix.Sync.Adapter.PlugApi.predefined_shape(adapter, shape)

    assert %{status: 200} =
             Phoenix.Sync.Adapter.PlugApi.call(
               shape_adapter,
               conn(:get, "/things"),
               %{"offset" => "now"}
             )

    assert_receive {:fetch_request, request}

    assert request.offset == "now"
    assert request.params["log"] == "changes_only"
  end

  test "streams SSE responses for server-defined shapes" do
    parent = self()

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {:sse_request, conn.query_params})

      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.put_resp_header("electric-offset", "1_0")
        |> Plug.Conn.put_resp_header("connection", "keep-alive, x-private-connection")
        |> Plug.Conn.put_resp_header("keep-alive", "timeout=5")
        |> Plug.Conn.put_resp_header("x-private-connection", "private")
        |> Plug.Conn.put_resp_header("set-cookie", "electric_session=secret")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          "data: {\"key\":\"things/1\",\"headers\":{\"operation\":\"insert\"},"
        )

      {:ok, conn} = Plug.Conn.chunk(conn, "\"value\":{\"value\":1}}\n\n")
      {:ok, conn} = Plug.Conn.chunk(conn, ": keep-alive\n\n")
      conn
    end

    {:ok, client} =
      Electric.Client.new(
        base_url: "http://electric.test",
        fetch: {Electric.Client.Fetch.HTTP, request: [plug: plug, raw: true]}
      )

    adapter = %ClientAdapter{client: client}

    shape =
      PredefinedShape.new!("things",
        transform: fn message -> put_in(message, ["value", "transformed"], true) end
      )

    assert {:ok, shape_adapter} =
             Phoenix.Sync.Adapter.PlugApi.predefined_shape(adapter, shape)

    response =
      Phoenix.Sync.Adapter.PlugApi.call(
        shape_adapter,
        conn(:get, "/things"),
        %{
          "offset" => "0_inf",
          "handle" => "things-1",
          "live" => "true",
          "live_sse" => "true"
        }
      )

    assert_receive {:sse_request, query}
    assert query["live"] == "true"
    assert query["live_sse"] == "true"
    assert query["table"] == "things"

    assert response.state == :chunked
    assert Plug.Conn.get_resp_header(response, "content-type") == ["text/event-stream"]
    assert Plug.Conn.get_resp_header(response, "electric-offset") == ["1_0"]
    assert Plug.Conn.get_resp_header(response, "connection") == []
    assert Plug.Conn.get_resp_header(response, "keep-alive") == []
    assert Plug.Conn.get_resp_header(response, "x-private-connection") == []
    assert Plug.Conn.get_resp_header(response, "set-cookie") == []

    assert response.resp_body ==
             "data: {\"headers\":{\"operation\":\"insert\"},\"key\":\"things/1\",\"value\":{\"transformed\":true,\"value\":1}}\n\n: keep-alive\n\n"
  end

  test "passes malformed SSE data frames through without invoking transforms" do
    plug = fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, "data: {not-json}\n\n")
      conn
    end

    shape_adapter =
      http_shape_adapter!(plug,
        transform: fn _message -> raise "malformed frames must not be transformed" end
      )

    response =
      Phoenix.Sync.Adapter.PlugApi.call(
        shape_adapter,
        conn(:get, "/things"),
        %{
          "offset" => "0_inf",
          "handle" => "things-1",
          "live" => "true",
          "live_sse" => "true"
        }
      )

    assert response.status == 200
    assert response.resp_body == "data: {not-json}\n\n"
  end

  test "raises an upstream SSE transport failure before sending a response" do
    plug = fn conn -> Req.Test.transport_error(conn, :timeout) end
    shape_adapter = http_shape_adapter!(plug)

    assert_raise Req.TransportError, fn ->
      Phoenix.Sync.Adapter.PlugApi.call(
        shape_adapter,
        conn(:get, "/things"),
        %{
          "offset" => "0_inf",
          "handle" => "things-1",
          "live" => "true",
          "live_sse" => "true"
        }
      )
    end
  end

  test "does not allow requests to widen configured queryable columns" do
    {:ok, client} =
      Electric.Client.new(
        base_url: "elixir://#{inspect(__MODULE__.Fetch)}",
        fetch: {MockFetch, parent: self()}
      )

    adapter = %ClientAdapter{client: client}
    shape = PredefinedShape.new!("things", queryable_columns: ["id", "visible"])

    assert {:ok, shape_adapter} =
             Phoenix.Sync.Adapter.PlugApi.predefined_shape(adapter, shape)

    assert %{status: 200} =
             Phoenix.Sync.Adapter.PlugApi.call(
               shape_adapter,
               conn(:get, "/things"),
               %{"offset" => "-1", "queryable_columns" => "id,secret"}
             )

    assert_receive {:fetch_request, request}

    assert request.params["queryable_columns"] == "id,visible"
  end

  test "forwards POST subset bodies separately from stream parameters" do
    parent = self()

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      raw_body = conn |> Req.Test.raw_body() |> IO.iodata_to_binary()

      send(parent, {
        :http_request,
        conn.method,
        conn.query_params,
        conn.req_headers,
        if(raw_body == "", do: nil, else: Jason.decode!(raw_body))
      })

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.put_resp_header("electric-offset", "3_0")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"metadata" => %{}, "data" => []}))
    end

    {:ok, client} =
      Electric.Client.new(
        base_url: "http://electric.test",
        authenticator: {Electric.Client.Authenticator.MockAuthenticator, salt: "post"},
        fetch: {Electric.Client.Fetch.HTTP, request: [plug: plug, raw: true]}
      )

    adapter = %ClientAdapter{client: client}
    shape = PredefinedShape.new!("things", log: :changes_only)

    assert {:ok, shape_adapter} =
             Phoenix.Sync.Adapter.PlugApi.predefined_shape(adapter, shape)

    body = %{
      "where" => "value = $1",
      "params" => ["one"],
      "order_by" => "id DESC",
      "limit" => 20,
      "offset" => 5
    }

    request_conn =
      conn(:post, "/things?offset=12_4&handle=shape-handle", Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-phoenix-auth", "allowed")
      |> Plug.Conn.fetch_query_params()
      |> Map.put(:body_params, body)

    params = Map.merge(request_conn.query_params, body)

    assert %{status: 200} =
             Phoenix.Sync.Adapter.PlugApi.call(shape_adapter, request_conn, params)

    assert_receive {:http_request, "POST", query, headers, ^body}

    assert query["offset"] == "12_4"
    assert query["handle"] == "shape-handle"
    assert query["table"] == "things"
    assert query["log"] == "changes_only"
    refute Map.has_key?(query, "where")
    assert {"x-phoenix-auth", "allowed"} in headers
    assert Enum.any?(headers, fn {name, _value} -> name == "electric-mock-auth" end)
  end

  test "returns non-success POST subset responses without transforming them" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.put_resp_header("electric-offset", "7_0")
      |> Plug.Conn.send_resp(422, Jason.encode!(%{"message" => "invalid subset"}))
    end

    shape_adapter =
      http_shape_adapter!(plug,
        transform: fn message -> put_in(message, ["transformed"], true) end
      )

    body = %{"where" => "missing = true", "limit" => 20}

    request_conn =
      conn(:post, "/things?offset=-1", Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.fetch_query_params()
      |> Map.put(:body_params, body)

    response =
      Phoenix.Sync.Adapter.PlugApi.call(
        shape_adapter,
        request_conn,
        Map.merge(request_conn.query_params, body)
      )

    assert response.status == 422
    assert Plug.Conn.get_resp_header(response, "electric-offset") == ["7_0"]
    assert Jason.decode!(response.resp_body) == %{"message" => "invalid subset"}
  end

  defp http_shape_adapter!(plug, shape_opts \\ []) do
    {:ok, client} =
      Electric.Client.new(
        base_url: "http://electric.test",
        fetch: {Electric.Client.Fetch.HTTP, request: [plug: plug, raw: true]}
      )

    adapter = %ClientAdapter{client: client}
    shape = PredefinedShape.new!("things", shape_opts)

    {:ok, shape_adapter} = Phoenix.Sync.Adapter.PlugApi.predefined_shape(adapter, shape)
    shape_adapter
  end
end
