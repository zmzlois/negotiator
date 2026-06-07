defmodule Negotiator.Prediction do
  @moduledoc """
  helpers for streaming queued continuation prediction.
  """

  @checkpoint_size 3

  def checkpoint_size, do: @checkpoint_size

  @doc """
  returns the checkpoint for a partial transcript.
  """
  def checkpoint(text) do
    div(word_count(text), @checkpoint_size)
  end

  def word_count(text) do
    ~r/[[:alnum:]'$-]+/u
    |> Regex.scan(text || "")
    |> length()
  end
end
