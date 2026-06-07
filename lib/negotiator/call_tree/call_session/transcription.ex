defmodule Negotiator.CallSession.Transcription do
  @moduledoc """
  commits buffered telnyx audio into speech-to-text.
  """

  alias Negotiator.CallSession.EventLog

  require Logger

  @doc """
  commits the current audio buffer when enough media has arrived.
  """
  def commit_if_ready(%{audio_buffer: <<>>} = state, _metadata), do: {:unchanged, state}

  def commit_if_ready(state, metadata) do
    if should_commit?(state, metadata) do
      commit(state, metadata)
    else
      {:unchanged, state}
    end
  end

  defp should_commit?(state, metadata) do
    Map.get(metadata, :force_transcribe?, false) ||
      Map.get(metadata, :commit?, false) ||
      byte_size(state.audio_buffer) >= state.transcription_commit_bytes
  end

  defp commit(state, metadata) do
    audio = state.audio_buffer
    state = Map.put(state, :audio_buffer, <<>>)

    Logger.info("transcription commit started",
      call_id: state.call_id,
      bytes: byte_size(audio),
      force?: Map.get(metadata, :force_transcribe?, false),
      commit?: Map.get(metadata, :commit?, false),
      turn_detection: Map.get(metadata, :turn_detection)
    )

    case state.speech_to_text.transcribe_ulaw(audio, transcription_opts(metadata)) do
      {:ok, %{text: text} = result} ->
        text = String.trim(text || "")

        Logger.info("transcription commit finished",
          call_id: state.call_id,
          provider: result.provider,
          text: text,
          bytes: byte_size(audio)
        )

        state =
          EventLog.append(state, :speech_transcribed, %{
            provider: result.provider,
            text: text,
            bytes: byte_size(audio),
            metadata: result.metadata
          })

        {:transcribed, state, text}

      {:error, reason} ->
        Logger.warning("transcription commit failed",
          call_id: state.call_id,
          reason: inspect(reason),
          bytes: byte_size(audio)
        )

        state =
          EventLog.append(state, :speech_transcription_failed, %{
            reason: inspect(reason),
            bytes: byte_size(audio)
          })

        {:failed, state, reason}
    end
  end

  defp transcription_opts(metadata) do
    metadata
    |> Map.take([:text, :local_text])
    |> Enum.to_list()
  end
end
