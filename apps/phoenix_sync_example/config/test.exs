import Config

database = "phoenix_sync_example_test#{System.get_env("MIX_TEST_PARTITION")}"

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

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :phoenix_sync_example, PhoenixSyncExample.Repo,
  url: database_url,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :phoenix_sync_example, PhoenixSyncExampleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "JxgUv3Dd0aEmBGFLgfyPpQPTidmD3BaW9NYtWDCnk0Yo3EaPDQgUNyLOXkm3+//h",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix_sync,
  env: config_env(),
  mode: :sandbox
