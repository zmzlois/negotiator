defmodule Negotiator.Retrieval do
  @moduledoc """
  retrieval boundary for moss or local retrieval.
  """

  @callback search(String.t(), keyword()) :: [map()]
end
