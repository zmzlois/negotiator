defmodule Negotiator.SileroVad.LLM do
  @moduledoc """
  model-backed probabilistic end-of-turn detector.
  """

  @behaviour Negotiator.SileroVad

  alias Negotiator.Tools
  alias Negotiator.SileroVad.{Decision, Probabilistic}

  require Logger

  @impl true
  def score(input) do
    started_at = System.monotonic_time(:millisecond)
    heuristic = Probabilistic.score(input)
    llm = Map.fetch!(input, :llm)

    decision =
      input
      |> Map.put(:heuristic, Map.from_struct(heuristic))
      |> then(&Tools.llm_complete(llm, :turn_detection, &1))
      |> parse_decision(heuristic)

    Logger.info("llm turn detection scored",
      call_id: input[:call_id],
      end_probability: decision.end_probability,
      should_reply: decision.should_reply?,
      reason: decision.reason,
      duration_ms: System.monotonic_time(:millisecond) - started_at
    )

    decision
  rescue
    error ->
      Logger.warning("llm turn detection failed; using heuristic",
        call_id: input[:call_id],
        reason: inspect(error)
      )

      Probabilistic.score(input)
  end

  defp parse_decision(content, fallback) when is_binary(content) do
    content
    |> extract_json()
    |> Jason.decode()
    |> case do
      {:ok, %{} = decoded} -> decision(decoded, fallback)
      _error -> fallback
    end
  end

  defp parse_decision(_content, fallback), do: fallback

  defp extract_json(content) do
    content = String.trim(content)

    cond do
      String.starts_with?(content, "```") ->
        content
        |> String.replace(~r/^```(?:json)?\s*/i, "")
        |> String.replace(~r/\s*```$/i, "")
        |> String.trim()

      true ->
        content
    end
  end

  defp decision(decoded, fallback) do
    probability =
      decoded
      |> value(["end_probability", "probability"])
      |> to_float(fallback.end_probability)
      |> clamp()

    %Decision{
      end_probability: probability,
      should_wait?: value(decoded, ["should_wait", "should_wait?"], probability < 0.72),
      should_reply?: value(decoded, ["should_reply", "should_reply?"], probability >= 0.72),
      reason: reason(value(decoded, ["reason"], Atom.to_string(fallback.reason)))
    }
  end

  defp value(map, keys, default \\ nil) do
    Enum.reduce_while(keys, default, fn key, acc ->
      if Map.has_key?(map, key) do
        {:halt, Map.get(map, key)}
      else
        {:cont, acc}
      end
    end)
  end

  defp to_float(value, _fallback) when is_float(value), do: value
  defp to_float(value, _fallback) when is_integer(value), do: value / 1

  defp to_float(value, fallback) when is_binary(value) do
    case Float.parse(value) do
      {float, _rest} -> float
      :error -> fallback
    end
  end

  defp to_float(_value, fallback), do: fallback

  defp clamp(value), do: value |> max(0.0) |> min(1.0)

  defp reason("likely_end_of_turn"), do: :likely_end_of_turn
  defp reason("wait_for_more_speech"), do: :wait_for_more_speech
  defp reason("interruption_risk"), do: :interruption_risk
  defp reason("continuation_expected"), do: :continuation_expected
  defp reason(_other), do: :model_estimate
end
