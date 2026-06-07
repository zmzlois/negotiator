import Config

config :negotiator, ecto_repos: [Negotiator.Repo]

config :negotiator, Negotiator.Repo,
  database: Path.expand("../priv/repo/#{config_env()}.db", __DIR__),
  pool_size: String.to_integer(System.get_env("DATABASE_POOL_SIZE") || "1")
