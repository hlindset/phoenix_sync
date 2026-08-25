defmodule Phoenix.Sync.Electric.SubsetParamsTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Phoenix.Sync.Electric

  describe "normalize_subset_params/2" do
    test "nests GET subset query parameters and preserves stream parameters" do
      params = %{
        "offset" => "12_4",
        "handle" => "shape-handle",
        "subset__where" => "value = $1",
        "subset__params" => ["one"]
      }

      assert Electric.normalize_subset_params(params, "GET") == %{
               "offset" => "12_4",
               "handle" => "shape-handle",
               "subset" => %{"where" => "value = $1", "params" => ["one"]}
             }
    end

    test "separates POST body subset parameters from query stream parameters" do
      conn =
        conn(:post, "/v1/shape?offset=12_4&handle=shape-handle", %{
          "where" => "value = $1",
          "params" => ["one"],
          "offset" => 5
        })
        |> Plug.Conn.fetch_query_params()

      params = Map.merge(conn.query_params, conn.body_params)

      assert Electric.normalize_subset_params(conn, params) == %{
               "offset" => "12_4",
               "handle" => "shape-handle",
               "subset" => %{"where" => "value = $1", "params" => ["one"], "offset" => 5}
             }
    end

    test "merges prefixed parameters into an existing subset" do
      assert Electric.normalize_subset_params(
               %{"subset" => %{"limit" => 10}, :subset__where => "active"},
               :get
             ) == %{"subset" => %{"limit" => 10, "where" => "active"}}
    end
  end
end
