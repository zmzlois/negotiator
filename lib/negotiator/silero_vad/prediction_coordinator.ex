defmodule Negotiator.PredictionCoordinator do
  @moduledoc """
  decides when to refresh queued continuation predictions based on
  transcript checkpoints. avoids redundant llm calls by tracking the
  last checkpoint that was predicted.
  """

  alias Negotiator.{Prediction, Prompts}

  @doc """
  checks whether a new prediction is needed after a final investor turn.
  returns {:refresh, state, job} or {:unchanged, state, candidates}.
  """
  def refresh_final_if_needed(state) do
    prompt_text = Prompts.queued_continuation_transcript(state.transcript)
    checkpoint = Prediction.checkpoint(prompt_text)

    if checkpoint > state.prediction_checkpoint do
      state = Map.put(state, :prediction_checkpoint, checkpoint)

      job = %{
        source: :final,
        prompt_text: prompt_text,
        checkpoint: checkpoint
      }

      {:refresh, state, job}
    else
      {:unchanged, state, state.candidates}
    end
  end

  @doc """
  checks whether a new prediction is needed from a partial investor transcript.
  returns {:refresh, state, job} or {:unchanged, state, candidates}.
  """
  def refresh_partial_if_needed(state, text) do
    prompt_text = Prompts.queued_continuation_transcript(state.transcript, text)
    checkpoint = Prediction.checkpoint(prompt_text)

    if checkpoint > state.prediction_checkpoint do
      state = Map.put(state, :prediction_checkpoint, checkpoint)

      job = %{
        source: :partial,
        prompt_text: prompt_text,
        checkpoint: checkpoint
      }

      {:refresh, state, job}
    else
      {:unchanged, state, state.candidates}
    end
  end
end
