defmodule Negotiator.CallSession.Speech do
  @moduledoc """
  records final speech turns with room provenance.
  older turns beyond the rolling window are only in the database.
  """

  alias Negotiator.CallSession.EventLog
  alias Negotiator.{Memory, Orchestration, Transcript, TranscriptStore}

  @max_transcript_turns 200

  @doc """
  appends a final speech turn and emits the matching event.
  """
  def record(state, role, text, opts \\ []) do
    room = Orchestration.room_for_role(state.orchestration, role)
    previous_count = length(state.transcript)
    transcript = Transcript.append(state.transcript, role, text, %{room: room})
    transcript = Enum.take(transcript, -@max_transcript_turns)
    source = Keyword.get(opts, :source, :human)

    state
    |> Map.put(:transcript, transcript)
    |> EventLog.append(:speech_final, %{
      role: role,
      room: room,
      source: source,
      text: String.trim(text)
    })
    |> persist_turn(new_turn(transcript, previous_count), source)
  end

  defp new_turn(transcript, previous_count) do
    if length(transcript) > previous_count, do: List.last(transcript)
  end

  defp persist_turn(state, nil, _source), do: state

  defp persist_turn(state, turn, source) do
    TranscriptStore.save_turn(%{
      call_id: state.call_id,
      sequence: state.sequence,
      role: turn.role,
      room: turn.room,
      source: source,
      text: turn.text,
      investor_identity: state.investor_identity,
      metadata: Map.drop(turn, [:role, :room, :text, :occurred_at]),
      occurred_at: turn.occurred_at
    })

    Memory.async(state.call_id, fn ->
      Memory.index_transcript(state.call_id, %{
        role: turn.role,
        room: turn.room,
        text: turn.text,
        sequence: state.sequence
      })
    end)

    state
  end
end
