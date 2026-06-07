defmodule NegotiatorWeb.CallSocket do
  @moduledoc """
  websocket handler for desktop app real-time call state.
  pushes call snapshots on every state change instead of polling.
  """

  @behaviour WebSock

  alias Negotiator.CallSupervisor
  alias NegotiatorWeb.CallView

  require Logger

  @push_interval_ms 100

  @impl true
  def init(_opts) do
    schedule_push()
    Logger.info("call socket connected")
    {:ok, %{last_payload_hash: nil}}
  end

  @impl true
  def handle_in({payload, [opcode: :text]}, state) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "ping"}} ->
        {:push, {:text, Jason.encode!(%{type: "pong"})}, state}

      _ ->
        {:ok, state}
    end
  end

  def handle_in(_message, state), do: {:ok, state}

  @impl true
  def handle_info(:push_state, state) do
    schedule_push()
    push_if_changed(state)
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state) do
    Logger.info("call socket disconnected")
    :ok
  end

  defp schedule_push do
    Process.send_after(self(), :push_state, @push_interval_ms)
  end

  defp push_if_changed(state) do
    calls =
      CallSupervisor.active_calls()
      |> Enum.map(&CallView.summary/1)

    payload = %{type: "calls", calls: calls}
    hash = :erlang.phash2(calls)

    if hash != state.last_payload_hash do
      json = NegotiatorWeb.Json.encode(payload)
      {:push, {:text, json}, %{state | last_payload_hash: hash}}
    else
      {:ok, state}
    end
  end
end
