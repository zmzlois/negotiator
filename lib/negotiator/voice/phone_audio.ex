defmodule Negotiator.Voice.PhoneAudio do
  @moduledoc """
  identifies audio that can be sent directly to telnyx media streaming.
  """

  @telnyx_format "audio/pcmu"

  def telnyx_format, do: @telnyx_format

  def telnyx_ready?(%{format: format, metadata: metadata}) do
    telnyx_ready_format?(format) or telnyx_ready_output_format?(metadata[:output_format])
  end

  def telnyx_ready?(_output), do: false

  defp telnyx_ready_format?(format) when is_binary(format) do
    format in [@telnyx_format, "audio/basic", "audio/ulaw", "audio/x-mulaw"]
  end

  defp telnyx_ready_format?(_format), do: false

  defp telnyx_ready_output_format?(format) when is_binary(format) do
    String.starts_with?(format, "ulaw_")
  end

  defp telnyx_ready_output_format?(_format), do: false
end
