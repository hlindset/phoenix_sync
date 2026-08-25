defmodule Phoenix.Sync.ClientOptionsTest do
  use ExUnit.Case, async: true

  test "adds changes-only mode to a custom client's stream requests" do
    {:ok, client} = Electric.Client.Mock.new()

    stream =
      Phoenix.Sync.Client.stream(
        table: "todos",
        log: :changes_only,
        live: false,
        client: client
      )

    assert stream.client.params["log"] == "changes_only"
  end
end
