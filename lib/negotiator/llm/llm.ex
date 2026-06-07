defmodule Negotiator.LLM do
  @moduledoc """
  llm boundary for simulated roles and production models.
  """

  alias Negotiator.Env

  @callback complete(atom(), map()) :: String.t() | [String.t()]
  @callback stream_complete(atom(), map()) :: Enumerable.t()

  @optional_callbacks [stream_complete: 2]

  @doc """
  streams llm output as sentences. falls back to complete/2 as a single sentence
  when streaming is disabled or the adapter doesn't support it.
  """
  def stream_sentences(module, task, input) do
    if streaming_enabled?() and function_exported?(module, :stream_complete, 2) do
      module.stream_complete(task, input)
    else
      [module.complete(task, input)]
    end
  end

  defp streaming_enabled? do
    Env.get("NEGOTIATOR_LLM_STREAMING", "") in ["1", "true"]
  end
end
