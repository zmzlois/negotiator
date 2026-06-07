defmodule Negotiator.CallSession.EventLog do
  @moduledoc """
  appends ordered call events with a rolling window cap.
  older events are trimmed to prevent unbounded memory growth.
  """

  @max_events 500

  @doc """
  appends one event, advances the sequence, and trims to the rolling window.
  """
  def append(state, type, payload) do
    sequence = state.sequence + 1

    event = %{
      sequence: sequence,
      type: type,
      payload: payload,
      occurred_at: DateTime.utc_now()
    }

    Negotiator.Logging.call_event(state.call_id, sequence, state.mode, type, payload)

    events = trim_events([event | Enum.reverse(state.events)])

    %{state | sequence: sequence, events: Enum.reverse(events)}
  end

  defp trim_events(events) when length(events) > @max_events do
    Enum.take(events, @max_events)
  end

  defp trim_events(events), do: events
end
