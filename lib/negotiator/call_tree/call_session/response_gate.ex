defmodule Negotiator.CallSession.ResponseGate do
  @moduledoc """
  calculates delay before a response should fire, based on multiple signals.
  prevents cutting users off mid-thought by gating response dispatch.
  """

  alias Negotiator.Env

  @doc """
  returns the number of milliseconds to wait before firing a response.
  takes the max of three signal-based delays.
  """
  def delay_ms(state) do
    now = System.monotonic_time(:millisecond)

    [
      post_transcription_delay(state, now),
      post_eot_delay(state),
      post_vad_silence_delay(state, now)
    ]
    |> Enum.max()
    |> max(0)
  end

  defp post_transcription_delay(state, now) do
    case state.last_transcription_at do
      nil -> 0
      ts -> ts + post_transcription_ms() - now
    end
  end

  defp post_eot_delay(state) do
    case state.last_eot_decision do
      %{should_reply?: false} -> post_eot_false_ms()
      _ -> 0
    end
  end

  defp post_vad_silence_delay(state, now) do
    case state.last_vad_silence_at do
      nil -> 0
      ts -> ts + post_vad_silence_ms() - now
    end
  end

  defp post_transcription_ms do
    integer_env("RESPONSE_DELAY_POST_TRANSCRIPTION_MS", 200)
  end

  defp post_eot_false_ms do
    integer_env("RESPONSE_DELAY_POST_EOT_FALSE_MS", 1500)
  end

  defp post_vad_silence_ms do
    integer_env("RESPONSE_DELAY_POST_VAD_SILENCE_MS", 400)
  end

  defp integer_env(name, default) do
    case Integer.parse(Env.get(name, "")) do
      {n, _} -> n
      :error -> default
    end
  end
end
