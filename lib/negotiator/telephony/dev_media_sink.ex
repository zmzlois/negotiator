defmodule Negotiator.Telephony.DevMediaSink do
  @moduledoc """
  local media sink that captures outbound phone audio events for development.
  """

  use GenServer

  alias Negotiator.{CallEvent, CallRegistry, CallSession, CallSupervisor}
  alias Negotiator.Telephony.Telnyx.MediaStream

  defstruct call_id: nil,
            participant: :founder,
            sequence: 0,
            events: []

  def start_link(opts) do
    call_id = Keyword.fetch!(opts, :call_id)

    participant =
      opts |> Keyword.get(:participant, :founder) |> MediaStream.normalize_participant()

    GenServer.start_link(__MODULE__, {call_id, participant}, name: via_name(call_id, participant))
  end

  @doc """
  connects a local sink as a media socket for the call participant.
  """
  def connect(call_id, participant) do
    participant = MediaStream.normalize_participant(participant)

    with {:ok, sink} <- start_or_get_sink(call_id, participant),
         {:ok, call_session} <- CallSupervisor.start_or_get_call(call_id: call_id),
         {:ok, _snapshot} <-
           CallSession.handle_event(
             call_session,
             CallEvent.register_media_socket(sink, %{participant: participant})
           ) do
      {:ok, snapshot(sink)}
    end
  end

  @doc """
  returns captured media events for a connected sink.
  """
  def events(call_id, participant) do
    participant = MediaStream.normalize_participant(participant)

    case whereis(call_id, participant) do
      pid when is_pid(pid) -> {:ok, snapshot(pid)}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  clears captured events for a connected sink.
  """
  def clear(call_id, participant) do
    participant = MediaStream.normalize_participant(participant)

    case whereis(call_id, participant) do
      pid when is_pid(pid) -> {:ok, GenServer.call(pid, :clear)}
      nil -> {:error, :not_found}
    end
  end

  @impl true
  def init({call_id, participant}) do
    {:ok, %__MODULE__{call_id: call_id, participant: participant}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, public_snapshot(state), state}
  end

  def handle_call(:clear, _from, state) do
    state = %{state | sequence: 0, events: []}
    {:reply, public_snapshot(state), state}
  end

  @impl true
  def handle_info({:play_audio, bytes, mark_name}, state) when is_binary(bytes) do
    state = append_event(state, :outbound_audio, %{
      bytes: byte_size(bytes),
      format: "audio/pcmu",
      payload_b64: Base.encode64(bytes)
    })

    acked? = acknowledge_mark(state.call_id, to_string(mark_name))

    {:noreply,
     append_event(state, :mark_audio, %{
       name: to_string(mark_name),
       acknowledged?: acked?
     })}
  end

  def handle_info({:outbound_audio, bytes, format}, state) when is_binary(bytes) do
    {:noreply,
     append_event(state, :outbound_audio, %{
       bytes: byte_size(bytes),
       format: format,
       payload_b64: Base.encode64(bytes)
     })}
  end

  def handle_info({:mark_audio, name}, state) do
    mark_name = to_string(name)
    acked? = acknowledge_mark(state.call_id, mark_name)

    {:noreply,
     append_event(state, :mark_audio, %{
       name: mark_name,
       acknowledged?: acked?
     })}
  end

  def handle_info({:clear_audio, reason}, state) do
    {:noreply, append_event(state, :clear_audio, %{reason: reason})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_or_get_sink(call_id, participant) do
    case whereis(call_id, participant) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case DynamicSupervisor.start_child(
               Negotiator.DevMediaSinkSupervisor,
               {__MODULE__, call_id: call_id, participant: participant}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  defp whereis(call_id, participant) do
    case Registry.lookup(CallRegistry, {:dev_media_sink, call_id, participant}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp via_name(call_id, participant) do
    {:via, Registry, {CallRegistry, {:dev_media_sink, call_id, participant}}}
  end

  defp snapshot(pid), do: GenServer.call(pid, :snapshot)

  defp acknowledge_mark(call_id, mark_name) do
    case CallSupervisor.lookup_call(call_id) do
      pid when is_pid(pid) ->
        CallSession.handle_event(
          pid,
          CallEvent.media_mark(mark_name, %{source: :dev_media_sink})
        )

        true

      nil ->
        false
    end
  end

  defp append_event(state, type, payload) do
    sequence = state.sequence + 1

    event = %{
      sequence: sequence,
      type: type,
      payload: payload,
      occurred_at: DateTime.utc_now()
    }

    %{state | sequence: sequence, events: state.events ++ [event]}
  end

  defp public_snapshot(state) do
    %{
      call_id: state.call_id,
      participant: state.participant,
      events: state.events,
      event_count: length(state.events)
    }
  end
end
