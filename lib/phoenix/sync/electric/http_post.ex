defmodule Phoenix.Sync.Electric.HttpPost do
  @moduledoc false

  alias Electric.Client
  alias Electric.Client.Fetch

  @spec request(Client.t(), Fetch.Request.t(), map()) ::
          Fetch.Response.t() | {:error, Fetch.Response.t() | Exception.t()}
  def request(
        %Client{fetch: {Electric.Client.Fetch.HTTP, fetch_opts}} = client,
        %Fetch.Request{} = request,
        body
      )
      when is_map(body) do
    timestamp = DateTime.utc_now()

    request =
      client
      |> Client.authenticate_request(request)
      |> Electric.Client.Fetch.HTTP.build_request(fetch_opts)

    request
    |> Req.merge(post_options(request, body))
    |> Req.request()
    |> wrap_response(timestamp)
  end

  def request(%Client{fetch: {fetcher, _opts}}, %Fetch.Request{}, _body) do
    {:error,
     ArgumentError.exception(
       "POST subset requests require Electric.Client.Fetch.HTTP, got: #{inspect(fetcher)}"
     )}
  end

  # Electric.Client's HTTP fetcher keeps Req options on the request without
  # re-merging them. Re-merge a configured test plug so Req selects the plug
  # adapter instead of attempting a network request.
  defp post_options(%Req.Request{options: options}, body) do
    case options[:plug] do
      nil -> [json: body]
      plug -> [json: body, plug: plug]
    end
  end

  defp wrap_response({:ok, %Req.Response{} = response}, timestamp) do
    %{status: status, headers: headers, body: body} = response
    response = Fetch.Response.decode!(status, headers, body, timestamp)

    if status in 200..299, do: response, else: {:error, response}
  end

  defp wrap_response({:error, _reason} = error, _timestamp), do: error
end
