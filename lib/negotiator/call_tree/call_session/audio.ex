defmodule Negotiator.CallSession.Audio do
  @moduledoc """
  routes synthesized audio back to the phone media socket.
  """

  alias Negotiator.CallSession.AudioGate

  require Logger

  # µ-law silence byte
  @ulaw_silence 0xFF

  @doc """
  returns the current phone audio route for a call state.
  """
  def route(state), do: AudioGate.route(state)

  @doc """
  sends voice output as paced rtp-aligned frames to the phone.
  """
  def send_voice_output(state, output, role \\ :small_talk_agent) do
    case AudioGate.voice_output(state, output, role) do
      {:send, recipients} ->
        mark_names =
          Enum.map(recipients, fn {participant, _pid} ->
            response_mark_name(state, role, participant)
          end)

        audio = strip_leading_silence(output.bytes || <<>>)

        Enum.zip(recipients, mark_names)
        |> Enum.each(fn {{_participant, pid}, mark_name} ->
          send(pid, {:play_audio, audio, mark_name})
        end)

        Logger.info("voice audio sent to phone",
          call_id: state.call_id,
          role: role,
          provider: output.provider,
          bytes: byte_size(audio),
          marks: mark_names,
          recipients: Enum.map(recipients, fn {participant, _pid} -> participant end)
        )

        {true, mark_names, nil}

      {:muted, reason} ->
        Logger.info("voice audio muted",
          call_id: state.call_id,
          role: role,
          provider: output.provider,
          reason: reason
        )

        {false, nil, reason}
    end
  end

  @doc """
  clears queued phone audio when an agent should stop speaking.
  """
  def clear_output(state, reason) do
    recipients = AudioGate.all_recipients(state)
    message = if fade_enabled?(), do: {:clear_audio_with_fade, reason}, else: {:clear_audio, reason}

    Enum.each(recipients, fn {_participant, pid} ->
      send(pid, message)
    end)

    Logger.info("phone audio clear requested",
      reason: reason,
      fade: fade_enabled?(),
      recipients: Enum.map(recipients, fn {participant, _pid} -> participant end)
    )

    recipients != []
  end

  defp fade_enabled? do
    Application.get_env(:negotiator, :interruption_fade, false) ||
      Negotiator.Env.get("INTERRUPTION_FADE_ENABLED", "") in ["1", "true"]
  end

  defp response_mark_name(state, role, participant) do
    "#{role}-#{participant}-response-#{state.sequence + 1}"
  end

  defp strip_leading_silence(<<@ulaw_silence, rest::binary>>), do: strip_leading_silence(rest)
  defp strip_leading_silence(audio), do: audio

end
