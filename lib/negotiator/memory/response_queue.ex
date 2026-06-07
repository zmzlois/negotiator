defmodule Negotiator.ResponseQueue do
  @moduledoc """
  ranked queue of pre-generated candidate responses for the small talk agent.
  candidates are scored by recency and source, with the best available for
  instant selection instead of waiting for a fresh llm call.
  """

  @max_candidates 5

  @doc """
  adds a candidate to the queue with metadata for ranking.
  """
  def enqueue(queue, text, metadata \\ %{}) when is_list(queue) and is_binary(text) do
    text = String.trim(text)

    if text == "" do
      queue
    else
      entry = %{text: text, metadata: metadata, queued_at: System.monotonic_time(:millisecond)}
      Enum.take([entry | queue], @max_candidates)
    end
  end

  @doc """
  returns the highest-ranked candidate, or nil if the queue is empty.
  """
  def best([]), do: nil
  def best([first | _rest]), do: first

  @doc """
  removes a candidate from the queue by its text or map reference.
  """
  def remove(queue, nil), do: queue

  def remove(queue, %{text: text}) when is_list(queue) do
    Enum.reject(queue, &(&1.text == text))
  end

  def remove(queue, text) when is_list(queue) and is_binary(text) do
    Enum.reject(queue, &(&1.text == text))
  end

  @doc """
  returns the text of all candidates in ranked order.
  """
  def texts(queue) when is_list(queue) do
    Enum.map(queue, & &1.text)
  end
end
