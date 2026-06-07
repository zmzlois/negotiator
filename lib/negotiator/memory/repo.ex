defmodule Negotiator.Repo do
  @moduledoc """
  persistent sqlite repo for durable negotiator state.
  """

  use Ecto.Repo,
    otp_app: :negotiator,
    adapter: Ecto.Adapters.SQLite3
end
