defmodule Phoenix.Sync.Electric.ClientAdapterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Phoenix.Sync.Electric.ClientAdapter
  alias Phoenix.Sync.PredefinedShape

  defmodule MockFetch do
    def validate_opts(opts), do: {:ok, opts}

    def fetch(request, parent: parent) do
      send(parent, {:fetch_request, request})

      %Electric.Client.Fetch.Response{
        status: 200,
        headers: %{},
        body: ["[]"]
      }
    end
  end

  test "forwards request headers to sync server" do
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

    assert %{status: 200} = Phoenix.Sync.Adapter.PlugApi.call(adapter, conn, %{offset: -1})
    assert_receive {:fetch_request, request}

    assert request.headers == %{
             "my-header-1" => ["my-header-1-value-1", "my-header-1-value-2"],
             "my-header-2" => ["my-header-2-value"]
           }
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
end
