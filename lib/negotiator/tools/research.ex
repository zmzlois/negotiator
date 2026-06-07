defmodule Negotiator.Research do
  @moduledoc """
  web search boundary for live call research.
  """

  @callback search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
end
