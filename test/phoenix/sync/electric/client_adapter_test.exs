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

    assert request.headers == [
             {"my-header-1", "my-header-1-value-1"},
             {"my-header-1", "my-header-1-value-2"},
             {"my-header-2", "my-header-2-value"}
           ]
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
end
