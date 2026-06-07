defmodule Negotiator.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    dotenv_report = Negotiator.Env.load_runtime_dotenv()
    Negotiator.Logging.configure_from_env()
    runtime_snapshot = Negotiator.RuntimeStatus.snapshot()
    Negotiator.RuntimeStatus.log_startup(runtime_snapshot)
    Negotiator.RuntimeStatus.enforce_live_voice_ready!(runtime_snapshot)

    children =
      [
        Negotiator.Repo,
        Negotiator.Memory,
        Negotiator.CallRegistry,
        Negotiator.CallSupervisor,
        {DynamicSupervisor, strategy: :one_for_one, name: Negotiator.DevMediaSinkSupervisor},
        {Task.Supervisor, name: Negotiator.ProviderTaskSupervisor}
      ] ++ http_children()

    opts = [strategy: :one_for_one, name: Negotiator.Supervisor]

    Logger.info("starting negotiator application",
      http_enabled?: http_enabled?(),
      dotenv_files_loaded: length(dotenv_report.loaded),
      dotenv_aliases_applied: length(dotenv_report.aliases)
    )

    result = Supervisor.start_link(children, opts)

    Task.start(fn -> Negotiator.Memory.MossSession.warm_model() end)

    result
  end

  defp http_children do
    if http_enabled?() do
      [
        {Bandit,
         plug: NegotiatorWeb.Router,
         port: Negotiator.Env.port(),
         thousand_island_options: [num_acceptors: 50]}
      ]
    else
      []
    end
  end

  defp http_enabled?, do: System.get_env("NEGOTIATOR_HTTP_ENABLED", "0") == "1"
end
