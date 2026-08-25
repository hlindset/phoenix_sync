defmodule Phoenix.Sync.Electric.ClientAdapter do
  @moduledoc false

  defstruct [:client, :shape_definition]

  defimpl Phoenix.Sync.Adapter.PlugApi do
    alias Electric.Client

    alias Phoenix.Sync.Electric.HttpPost
    alias Phoenix.Sync.PredefinedShape

    @subset_body_keys ~w(where order_by limit offset params where_expr order_by_expr)

    def predefined_shape(sync_client, %PredefinedShape{} = predefined_shape) do
      shape_client = PredefinedShape.client(sync_client.client, predefined_shape)

      {:ok,
       %Phoenix.Sync.Electric.ClientAdapter{
         client: shape_client,
         shape_definition: predefined_shape
       }}
    end

    def call(sync_client, conn, params) do
      {request, shape, body} = request(sync_client, conn, params)

      fetch_upstream(sync_client, conn, request, shape, body)
    end

    def response(sync_client, %{method: method} = conn, params)
        when method in ["GET", "POST"] do
      {request, shape, body} = request(sync_client, conn, params)

      make_request(sync_client, conn, request, shape, body)
    end

    def send_response(_sync_client, conn, response) do
      conn
      |> put_resp_headers(response.headers)
      |> Plug.Conn.send_resp(response.status, response.body)
    end

    # this is the server-defined shape route, so we want to only pass on the
    # per-request/stream position params and subset query params, leaving
    # the shape-definition params from the configured client.
    defp request(
           %{shape_definition: %PredefinedShape{} = shape} = sync_client,
           %{method: method} = conn,
           params
         ) do
      request_params = request_params(conn, params)

      {
        Client.request(
          sync_client.client,
          method: normalise_method(method),
          offset: request_params["offset"],
          shape_handle: request_params["handle"],
          live: live?(request_params["live"]),
          next_cursor: request_params["cursor"],
          params: stream_request_params(request_params)
        ),
        shape,
        request_body(conn, shape)
      }
    end

    # this version is the pure client-defined shape version
    defp request(sync_client, %{method: method} = conn, params) do
      {
        Client.request(
          sync_client.client,
          method: normalise_method(method),
          params: request_params(conn, params)
        ),
        nil,
        request_body(conn, nil)
      }
    end

    defp normalise_method(method), do: method |> String.downcase() |> String.to_atom()
    defp live?(live), do: live == "true"

    defp stream_request_params(params) do
      params
      |> Map.filter(fn {key, _} -> String.starts_with?(key, "subset__") end)
      |> maybe_put_live_sse(params["live_sse"])
    end

    defp maybe_put_live_sse(params, live_sse) when live_sse in [true, "true"],
      do: Map.put(params, "live_sse", "true")

    defp maybe_put_live_sse(params, _live_sse), do: params

    defp request_params(%{method: "POST", query_params: query_params}, _params),
      do: map_or_empty(query_params)

    defp request_params(_conn, params), do: params

    defp request_body(%{method: "POST", body_params: body_params}, %PredefinedShape{}) do
      subset_body(map_or_empty(body_params))
    end

    defp request_body(%{method: "POST", body_params: body_params}, nil),
      do: map_or_empty(body_params)

    defp request_body(_conn, _shape), do: nil

    defp subset_body(%{"subset" => subset}) when is_map(subset),
      do: %{"subset" => take_subset_keys(subset)}

    defp subset_body(%{subset: subset}) when is_map(subset),
      do: %{"subset" => take_subset_keys(subset)}

    defp subset_body(body), do: take_subset_keys(body)

    defp take_subset_keys(params) do
      Enum.reduce(params, %{}, fn {key, value}, subset ->
        key = to_string(key)
        if key in @subset_body_keys, do: Map.put(subset, key, value), else: subset
      end)
    end

    defp map_or_empty(%Plug.Conn.Unfetched{}), do: %{}
    defp map_or_empty(map) when is_map(map), do: map
    defp map_or_empty(_), do: %{}

    defp fetch_upstream(sync_client, conn, request, shape, body) do
      case {sync_client.client.fetch, request.live, request.params["live_sse"], body} do
        {{Electric.Client.Fetch.HTTP, fetch_opts}, true, "true", nil} ->
          stream_sse(sync_client.client, fetch_opts, conn, request, shape)

        _other ->
          response = make_request(sync_client, conn, request, shape, body)
          send_response(sync_client, conn, response)
      end
    end

    defp stream_sse(client, fetch_opts, conn, request, shape) do
      request = put_req_headers(request, conn.req_headers)
      transform_fun = PredefinedShape.transform_fun(shape)

      request =
        client
        |> Client.authenticate_request(request)
        |> Electric.Client.Fetch.HTTP.build_request(fetch_opts)

      into = fn {:data, data}, {request, response} ->
        {data, response} = transform_sse_chunk(data, response, transform_fun)

        if data == "" do
          {:cont, {request, response}}
        else
          conn =
            case Req.Response.get_private(response, :phoenix_sync_conn) do
              nil ->
                conn
                |> merge_req_response_headers(response)
                |> Plug.Conn.send_chunked(response.status)

              conn ->
                conn
            end

          case Plug.Conn.chunk(conn, data) do
            {:ok, conn} ->
              response = Req.Response.put_private(response, :phoenix_sync_conn, conn)
              {:cont, {request, response}}

            {:error, _reason} ->
              response = Req.Response.put_private(response, :phoenix_sync_conn, conn)
              {:halt, {request, response}}
          end
        end
      end

      req_opts =
        [into: into, retry: false]
        |> maybe_reuse_plug(request.options[:plug])

      case Req.request(request, req_opts) do
        {:ok, response} ->
          case Req.Response.get_private(response, :phoenix_sync_conn) do
            nil ->
              conn
              |> merge_req_response_headers(response)
              |> Plug.Conn.send_resp(response.status, response.body)

            conn ->
              conn
          end

        {:error, exception} ->
          raise exception
      end
    end

    defp maybe_reuse_plug(opts, nil), do: opts
    defp maybe_reuse_plug(opts, plug), do: Keyword.put(opts, :plug, plug)

    defp transform_sse_chunk(data, response, nil), do: {data, response}

    defp transform_sse_chunk(data, response, transform_fun) do
      buffer = Req.Response.get_private(response, :phoenix_sync_sse_buffer, "") <> data
      parts = String.split(buffer, "\n\n")
      {remaining, frames} = List.pop_at(parts, -1)

      data = Enum.map_join(frames, &transform_sse_frame(&1, transform_fun))
      response = Req.Response.put_private(response, :phoenix_sync_sse_buffer, remaining)

      {data, response}
    end

    defp transform_sse_frame("data: " <> json, transform_fun) do
      case Jason.decode(json) do
        {:ok, message} ->
          [message]
          |> Phoenix.Sync.Electric.map_response_body(transform_fun)
          |> Enum.map_join(fn message -> "data: #{Jason.encode!(message)}\n\n" end)

        {:error, _reason} ->
          "data: #{json}\n\n"
      end
    end

    defp transform_sse_frame(frame, _transform_fun), do: frame <> "\n\n"

    defp merge_req_response_headers(conn, response) do
      response
      |> Req.Response.to_map()
      |> Map.fetch!(:headers)
      |> Enum.reject(fn {name, _value} -> name == "transfer-encoding" end)
      |> then(&Plug.Conn.merge_resp_headers(conn, &1))
    end

    defp make_request(sync_client, conn, request, shape, body) do
      request = put_req_headers(request, conn.req_headers)

      response =
        case fetch_request(sync_client.client, request, body) do
          %Client.Fetch.Response{} = response -> response
          {:error, %Client.Fetch.Response{} = response} -> response
          {:error, exception} when is_exception(exception) -> raise exception
        end

      body =
        if response.status == 200 do
          Phoenix.Sync.Electric.map_response_body(
            response.body,
            PredefinedShape.transform_fun(shape)
          )
        else
          response.body
        end

      %{response | body: body}
    end

    defp fetch_request(client, request, nil), do: Client.Fetch.request(client, request)
    defp fetch_request(client, request, body), do: HttpPost.request(client, request, body)

    defp put_req_headers(request, headers) do
      merged_headers =
        Enum.reduce(headers, request.headers, fn {header, value}, acc ->
          Map.update(acc, header, [value], fn existing -> [value | List.wrap(existing)] end)
        end)

      %{request | headers: merged_headers}
    end

    defp put_resp_headers(conn, headers) do
      resp_headers =
        headers
        |> Map.delete("transfer-encoding")
        |> expand_headers()

      Plug.Conn.merge_resp_headers(conn, resp_headers)
    end

    # turn headers into a list which is more compatible than a map
    # representation as it preserves multiple values for a header.
    defp expand_headers(headers) when is_map(headers) do
      Enum.flat_map(headers, fn {k, v} -> Enum.map(List.wrap(v), &{k, &1}) end)
    end
  end
end
