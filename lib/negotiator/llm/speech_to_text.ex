defmodule Negotiator.SpeechToText do
  @moduledoc """
  speech-to-text boundary for telnyx audio.
  """

  defmodule Result do
    @moduledoc """
    transcription result returned by a speech transcription provider.
    """

    defstruct provider: nil, text: "", metadata: %{}
  end

  @callback transcribe_ulaw(binary(), keyword()) :: {:ok, Result.t()} | {:error, term()}
end
