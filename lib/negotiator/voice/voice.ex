defmodule Negotiator.Voice do
  @moduledoc """
  speech synthesis boundary for agent voice output.
  """

  defmodule Output do
    @moduledoc """
    synthesized speech metadata.
    """

    defstruct provider: nil, format: nil, bytes: nil, metadata: %{}
  end

  @callback synthesize(String.t(), keyword()) :: {:ok, Output.t()} | {:error, term()}
end
