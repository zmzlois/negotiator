defmodule Negotiator.Telephony.Telnyx.MediaStream do
  @moduledoc """
  normalizes telnyx media-stream websocket frames.
  """

  @doc """
  decodes one text websocket payload into a telnyx event map.
  """
  def decode_text(payload) when is_binary(payload), do: Jason.decode(payload)

  @doc """
  encodes outbound phone audio for telnyx bidirectional media streaming.
  """
  def encode_media(bytes) when is_binary(bytes) do
    Jason.encode!(%{
      event: "media",
      media: %{payload: Base.encode64(bytes)}
    })
  end

  @doc """
  encodes an audio clear frame.
  """
  def encode_clear, do: Jason.encode!(%{event: "clear"})

  @doc """
  encodes a playback mark frame.
  """
  def encode_mark(name) do
    Jason.encode!(%{
      event: "mark",
      mark: %{name: to_string(name)}
    })
  end

  @doc """
  extracts the telnyx stream id from an event, preserving the previous id when absent.
  """
  def stream_id(%{"stream_id" => stream_id}, _fallback) when is_binary(stream_id) do
    stream_id
  end

  def stream_id(%{"streamId" => stream_id}, _fallback) when is_binary(stream_id) do
    stream_id
  end

  def stream_id(_event, fallback), do: fallback

  @doc """
  decodes one inbound media frame into bytes and normalized metadata.
  """
  def decode_media(%{"event" => "media", "media" => %{"payload" => payload} = media})
      when is_binary(payload) do
    case Base.decode64(payload) do
      {:ok, bytes} ->
        raw_track = media["track"]

        {:ok, bytes,
         %{
           track: normalize_track(raw_track),
           raw_track: raw_track,
           timestamp: media["timestamp"]
         }}

      :error ->
        {:error, :bad_base64}
    end
  end

  def decode_media(_event), do: {:error, :not_media}

  @doc """
  normalizes telnyx track names across old and new payload shapes.
  """
  def normalize_track(nil), do: :inbound

  def normalize_track(track) when is_binary(track) do
    track
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      value when value in ["inbound", "inbound_track"] -> :inbound
      value when value in ["outbound", "outbound_track"] -> :outbound
      value -> value
    end
  end

  def normalize_track(track), do: track

  @doc """
  normalizes the app-side participant encoded in the media websocket path.
  """
  def normalize_participant(participant) when participant in [:founder, :investor] do
    participant
  end

  def normalize_participant(participant) when is_binary(participant) do
    case String.downcase(participant) do
      "investor" -> :investor
      _other -> :founder
    end
  end

  def normalize_participant(_participant), do: :founder
end
