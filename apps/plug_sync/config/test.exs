import Config

database = "plug_sync_test#{System.get_env("MIX_TEST_PARTITION")}"

default_database_url =
  %URI{
    scheme: "postgresql",
    userinfo: "postgres:password",
    host: System.get_env("PHOENIX_SYNC_TEST_DB_HOST", "localhost"),
    port: String.to_integer(System.get_env("PHOENIX_SYNC_TEST_DB_PORT", "55555")),
    path: "/#{database}",
    query: "sslmode=disable"
  }
  |> URI.to_string()

database_url =
  System.get_env("DATABASE_URL", default_database_url)
  |> URI.parse()
  |> Map.put(:path, "/#{database}")
  |> URI.to_string()

config :plug_sync,
  ecto_repos: [PlugSync.Repo],
  start_server: false

config :plug_sync, PlugSync.Repo,
  url: database_url,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :phoenix_sync, mode: :sandbox, env: config_env()
