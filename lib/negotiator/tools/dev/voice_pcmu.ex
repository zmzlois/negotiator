defmodule Negotiator.Dev.VoicePcmu do
  @moduledoc """
  dev-only telnyx-ready voice fixture for exercising the phone audio path.
  """

  @behaviour Negotiator.Voice

  alias Negotiator.Voice.{Output, PhoneAudio}

  @impl true
  def synthesize(text, opts \\ []) do
    role = Keyword.get(opts, :role, :small_talk_agent)
    duration_ms = max(240, min(2_400, String.length(to_string(text || "")) * 30))
    bytes = :binary.copy(<<0xFF>>, div(8_000 * duration_ms, 1_000))

    {:ok,
     %Output{
       provider: :dev_pcmu,
       format: PhoneAudio.telnyx_format(),
       bytes: bytes,
       metadata: %{role: role, output_format: "ulaw_8000", duration_ms: duration_ms}
     }}
  end
end
