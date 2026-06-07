defmodule Negotiator.CallSession.TranscriptionQueue do
  @moduledoc """
  tracks the transcript turn that a response is currently using.
  """

  defstruct latest: nil,
            queued: nil,
            synthesizing: nil,
            playing: nil

  @doc """
  returns an empty transcription queue.
  """
  def new, do: %__MODULE__{}

  @doc """
  clears every transcription lifecycle slot.
  """
  def clear(_queue), do: new()

  @doc """
  clears response-specific slots while preserving the latest heard words.
  """
  def clear_response_state(%__MODULE__{} = queue) do
    %{queue | queued: nil, synthesizing: nil, playing: nil}
  end

  @doc """
  records the latest partial or interim transcript.
  """
  def set_latest(%__MODULE__{} = queue, role, text, metadata \\ %{}) do
    item = build_item(queue, role, text, metadata, false)
    %{queue | latest: item}
  end

  @doc """
  records a final transcript turn that may need a response.
  """
  def queue_final(%__MODULE__{} = queue, role, text, metadata \\ %{}) do
    item = build_item(queue, role, text, metadata, true)
    %{queue | latest: item, queued: item}
  end

  @doc """
  moves the queued transcript into the synthesis slot for a provider job.
  """
  def start_synthesizing(%__MODULE__{queued: nil} = queue, _ref, _kind, _role), do: {queue, nil}

  def start_synthesizing(%__MODULE__{queued: queued} = queue, ref, kind, role) do
    item =
      queued
      |> Map.put(:response_ref, inspect(ref))
      |> Map.put(:response_kind, kind)
      |> Map.put(:response_role, role)
      |> Map.put(:synthesizing_at, DateTime.utc_now())

    {%{queue | queued: nil, synthesizing: item}, item}
  end

  @doc """
  moves the synthesizing transcript into the playback slot.
  """
  def start_playing(%__MODULE__{synthesizing: nil} = queue, _role, _text, _playback_mark),
    do: {queue, nil}

  def start_playing(%__MODULE__{synthesizing: synthesizing} = queue, role, text, playback_mark) do
    item =
      synthesizing
      |> Map.put(:playing_role, role)
      |> Map.put(:sentence_text, String.trim(to_string(text || "")))
      |> Map.put(:playback_mark, primary_mark(playback_mark))
      |> Map.put(:playing_at, DateTime.utc_now())

    {%{queue | synthesizing: nil, playing: item}, item}
  end

  @doc """
  clears the playing slot when its playback mark completes.
  """
  def finish_playing(%__MODULE__{playing: %{playback_mark: mark}} = queue, mark),
    do: %{queue | playing: nil}

  def finish_playing(%__MODULE__{} = queue, _mark), do: queue

  @doc """
  clears the current playback slot.
  """
  def clear_playing(%__MODULE__{} = queue), do: %{queue | playing: nil}

  @doc """
  clears every slot whose transcript id or group id matches the params.
  """
  def unset_where(%__MODULE__{} = queue, params) when is_map(params) do
    %{
      queue
      | latest: keep_unless_match(queue.latest, params),
        queued: keep_unless_match(queue.queued, params),
        synthesizing: keep_unless_match(queue.synthesizing, params),
        playing: keep_unless_match(queue.playing, params)
    }
  end

  def metadata(nil), do: %{}

  def metadata(item) when is_map(item) do
    %{
      transcription_id: item.id,
      transcription_group_id: item.group_id,
      transcription_role: item.role,
      transcription_text: item.text
    }
  end

  defp build_item(queue, role, text, metadata, final?) do
    metadata = Map.new(metadata || %{})
    text = String.trim(to_string(text || ""))
    group_id = metadata_group_id(metadata) || current_group_id(queue, role) || queue_id("group")

    %{
      id: metadata_id(metadata) || queue_id("transcription"),
      group_id: group_id,
      role: role,
      text: text,
      final?: final?,
      confidence: Map.get(metadata, :confidence) || Map.get(metadata, "confidence"),
      source: Map.get(metadata, :source) || Map.get(metadata, "source"),
      occurred_at: DateTime.utc_now()
    }
  end

  defp current_group_id(%__MODULE__{latest: %{role: role, group_id: group_id}}, role),
    do: group_id

  defp current_group_id(_queue, _role), do: nil

  defp metadata_id(metadata) do
    first_present([
      Map.get(metadata, :id),
      Map.get(metadata, "id"),
      Map.get(metadata, :transcription_id),
      Map.get(metadata, "transcription_id")
    ])
  end

  defp metadata_group_id(metadata) do
    first_present([
      Map.get(metadata, :group_id),
      Map.get(metadata, "group_id"),
      Map.get(metadata, :transcription_group_id),
      Map.get(metadata, "transcription_group_id"),
      Map.get(metadata, :call_leg_id),
      Map.get(metadata, "call_leg_id")
    ])
  end

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      nil ->
        nil

      value ->
        to_string(value)
    end)
  end

  defp keep_unless_match(nil, _params), do: nil

  defp keep_unless_match(item, params) do
    id = Map.get(params, :id) || Map.get(params, "id")
    group_id = Map.get(params, :group_id) || Map.get(params, "group_id")

    if item.id == id or item.group_id == group_id do
      nil
    else
      item
    end
  end

  defp primary_mark([mark | _rest]), do: mark
  defp primary_mark(mark), do: mark

  defp queue_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
