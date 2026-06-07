defmodule Negotiator.MixProject do
  use Mix.Project

  def project do
    [
      app: :negotiator,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Negotiator.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.6"},
      {:websock_adapter, "~> 0.5"},
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, "~> 0.24.0"},
      {:moss, "~> 1.0"}
    ]
  end
end
