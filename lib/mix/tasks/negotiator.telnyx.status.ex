defmodule Mix.Tasks.Negotiator.Telnyx.Status do
  @moduledoc """
  prints secret-safe telnyx carrier-call readiness.
  """

  use Mix.Task

  @shortdoc "checks telnyx carrier-call readiness"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    snapshot = Negotiator.Telephony.Telnyx.Readiness.snapshot()

    Mix.shell().info(Jason.encode!(snapshot, pretty: true))

    unless snapshot.ready? do
      Mix.raise("telnyx carrier-call readiness is incomplete")
    end
  end
end
