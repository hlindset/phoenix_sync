import Config

if config_env() == :test do
  # port = 3333
  default_database_url =
    %URI{
      scheme: "postgresql",
      userinfo: "postgres:password",
      host: System.get_env("PHOENIX_SYNC_TEST_DB_HOST", "localhost"),
      port: String.to_integer(System.get_env("PHOENIX_SYNC_TEST_DB_PORT", "55555")),
      path: "/phoenix_sync",
      query: "sslmode=disable"
    }
    |> URI.to_string()

  database_url = System.get_env("DATABASE_URL", default_database_url)
  electric_connection_opts = Electric.Config.parse_postgresql_uri!(database_url)

  repo_connection_opts =
    electric_connection_opts
    |> Electric.Utils.deobfuscate_password()
    |> Keyword.pop(:sslmode)
    |> case do
      {:require, connection_opts} -> Keyword.put(connection_opts, :ssl, true)
      {_sslmode, connection_opts} -> connection_opts
    end

  config :electric,
    start_in_library_mode: true,
    connection_opts: electric_connection_opts,
    # enable the http api so that the client tests against a real endpoint can
    # run against our embedded electric instance.
    # enable_http_api: true,
    # service_port: port,
    allow_shape_deletion?: false,
    # use a non-default replication stream id so we can run the client
    # tests at the same time as an active electric instance
    replication_stream_id: "phoenix_sync_tests",
    storage_dir: Path.join(System.tmp_dir!(), "electric/client-tests#{System.monotonic_time()}")

  config :phoenix_sync, Support.Repo, repo_connection_opts
  config :phoenix_sync, Support.ConfigTestRepo, Keyword.delete(repo_connection_opts, :port)
  config :phoenix_sync, Support.SandboxRepo, repo_connection_opts
end
