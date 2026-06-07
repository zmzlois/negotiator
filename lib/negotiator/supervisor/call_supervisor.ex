defmodule Negotiator.CallSupervisor do
  @moduledoc """
  supervises active call sessions.
  """

  use DynamicSupervisor

  alias Negotiator.CallRegistry
  alias Negotiator.CallSession

  require Logger

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  starts one negotiation call.
  """
  def start_call(opts \\ []) do
    call_id = Keyword.get(opts, :call_id, "call-#{System.unique_integer([:positive])}")
    Logger.info("starting call session", call_id: call_id)

    opts =
      opts
      |> Keyword.put(:call_id, call_id)
      |> Keyword.put(:name, CallRegistry.via_call_session(call_id))

    DynamicSupervisor.start_child(__MODULE__, {CallSession, opts})
  end

  @doc """
  returns the call session for a telnyx call_control_id.
  """
  def lookup_call(call_id), do: CallRegistry.whereis_call_session(call_id)

  @doc """
  lists active call sessions.
  """
  def active_calls, do: CallRegistry.active_call_sessions()

  @doc """
  returns a snapshot for an active call.
  """
  def call_snapshot(call_id) do
    case lookup_call(call_id) do
      pid when is_pid(pid) -> {:ok, CallSession.state(pid)}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  starts a call session if it does not already exist.
  """
  def start_or_get_call(opts) do
    call_id = Keyword.fetch!(opts, :call_id)

    case lookup_call(call_id) do
      pid when is_pid(pid) ->
        Logger.debug("using existing call session", call_id: call_id, pid: inspect(pid))
        {:ok, pid}

      nil ->
        case start_call(opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  @doc """
  terminates an active call session.
  """
  def stop_call(call_id) do
    case lookup_call(call_id) do
      pid when is_pid(pid) ->
        Logger.info("stopping call session", call_id: call_id, pid: inspect(pid))
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      nil ->
        Logger.debug("stop call ignored; session not found", call_id: call_id)
        :ok
    end
  end
end
