defmodule Negotiator.Dev.SpeechToText do
  @moduledoc """
  dev-only transcription fixture for injected media-frame text.
  """

  @behaviour Negotiator.SpeechToText

  alias Negotiator.SpeechToText.Result

  @impl true
  def transcribe_ulaw(_bytes, opts \\ []) do
    text = Keyword.get(opts, :text) || Keyword.get(opts, :local_text) || ""

    {:ok,
     %Result{
       provider: :dev_fixture,
       text: text,
       metadata: %{source: :dev_media_frame}
     }}
  end
end
