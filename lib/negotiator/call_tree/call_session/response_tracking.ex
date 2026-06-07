defmodule Negotiator.CallSession.ResponseTracking do
  @moduledoc """
  tracks async response jobs and phone playback marks for a call.
  """

  alias Negotiator.CallSession.TranscriptionQueue

  @doc """
  tracks an active provider job that may later speak into a call room.
  """
  def track_job(state, ref, kind, role) do
    ref_key = inspect(ref)

    {queue, transcription} =
      TranscriptionQueue.start_synthesizing(state.transcription_queue, ref, kind, role)

    metadata =
      %{
        kind: kind,
        role: role,
        started_at: DateTime.utc_now()
      }
      |> Map.merge(TranscriptionQueue.metadata(transcription))

    state
    |> Map.put(:transcription_queue, queue)
    |> Map.update!(:active_response_refs, &Map.put(&1, ref_key, metadata))
  end

  @doc """
  removes an active provider job if the result still belongs to this call state.
  """
  def take_job(state, ref, kind) do
    ref_key = inspect(ref)

    case Map.fetch(state.active_response_refs, ref_key) do
      {:ok, %{kind: ^kind}} ->
        {:ok, Map.update!(state, :active_response_refs, &Map.delete(&1, ref_key))}

      _missing_or_wrong_kind ->
        :stale
    end
  end

  @doc """
  tracks a telnyx playback mark sent after synthesized audio.
  """
  def track_playback_mark(state, nil, _role, _output), do: state

  def track_playback_mark(state, mark_names, role, output) when is_list(mark_names) do
    Enum.reduce(mark_names, state, fn mark_name, state ->
      track_playback_mark(state, mark_name, role, output)
    end)
  end

  def track_playback_mark(state, mark_name, role, output) do
    metadata =
      %{
        role: role,
        provider: output.provider,
        started_at: DateTime.utc_now()
      }
      |> Map.merge(TranscriptionQueue.metadata(state.transcription_queue.playing))

    Map.update!(state, :active_playback_marks, &Map.put(&1, mark_name, metadata))
  end

  @doc """
  removes a playback mark when telnyx confirms queued audio has played.
  """
  def take_playback_mark(_state, nil), do: :stale

  def take_playback_mark(state, mark_name) do
    case Map.fetch(state.active_playback_marks, mark_name) do
      {:ok, metadata} ->
        state = Map.update!(state, :active_playback_marks, &Map.delete(&1, mark_name))
        {:ok, state, metadata}

      :error ->
        :stale
    end
  end
end
