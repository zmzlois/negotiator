defmodule Negotiator.SileroVad.Probabilistic do
  @moduledoc """
  lightweight probabilistic turn detector for local development.

  production should replace this with a model-backed turn detector, but this
  gives the elixir state machine the same contract now.
  """

  @behaviour Negotiator.SileroVad

  alias Negotiator.SileroVad.Decision

  @impl true
  def score(input) do
    text = Map.get(input, :text, "")
    silence_ms = Map.get(input, :silence_ms, 0)
    stable_words = Map.get(input, :stable_words, word_count(text))

    probability =
      0.12
      |> add(if silence_ms >= 1_200, do: 0.35, else: silence_ms / 4_000)
      |> add(if terminal_sentence?(text), do: 0.3, else: 0.0)
      |> add(if stable_words >= 8, do: 0.15, else: stable_words / 80)
      |> add(if continuation_phrase?(text), do: -0.4, else: 0.0)
      |> clamp()

    %Decision{
      end_probability: probability,
      should_wait?: probability < 0.72,
      should_reply?: probability >= 0.72,
      reason: reason(probability)
    }
  end

  defp terminal_sentence?(text), do: String.match?(String.trim(text), ~r/[.!?]$/)

  defp continuation_phrase?(text) do
    text = String.downcase(String.trim(text))

    Regex.match?(
      ~r/(^|\s)(and|but|because|so|which is|what i mean is|the reason is)$/u,
      text
    )
  end

  defp word_count(text) do
    ~r/[[:alnum:]'$-]+/u
    |> Regex.scan(text || "")
    |> length()
  end

  defp add(value, delta), do: value + delta
  defp clamp(value), do: value |> max(0.0) |> min(1.0)
  defp reason(probability) when probability >= 0.72, do: :likely_end_of_turn
  defp reason(_probability), do: :wait_for_more_speech
end
