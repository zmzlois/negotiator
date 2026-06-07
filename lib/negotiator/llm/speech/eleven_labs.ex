defmodule Negotiator.LLM.Speech.ElevenLabs do
  @moduledoc """
  elevenlabs streaming text-to-speech adapter for the founder voice clone.
  """

  @behaviour Negotiator.Voice

  alias Negotiator.{Env, Tools}
  alias Negotiator.LLM.Speech.Models
  alias Negotiator.Voice.{Output, PhoneAudio}

  require Logger

  @base_url "https://api.elevenlabs.io"
  @impl true
  def synthesize(text, opts \\ []) do
    api_key = Keyword.get_lazy(opts, :api_key, fn -> Env.fetch!("ELEVENLABS_API_KEY") end)
    voice_id = Keyword.get_lazy(opts, :voice_id, fn -> Env.fetch!("ELEVENLABS_VOICE_ID") end)
    model_id = Keyword.get(opts, :model_id, Models.elevenlabs_speech())

    output_format =
      Keyword.get(
        opts,
        :output_format,
        Models.elevenlabs_output_format()
      )

    url = url(voice_id, output_format)
    started_at = System.monotonic_time(:millisecond)

    Logger.info("elevenlabs synthesis started",
      provider: :elevenlabs,
      voice_id: voice_id,
      model_id: model_id,
      output_format: output_format,
      text_chars: String.length(text || "")
    )

    body = %{
      text: text,
      model_id: model_id,
      voice_settings: %{
        stability: 0.65,
        similarity_boost: 0.75,
        style: 0.10,
        use_speaker_boost: false
      }
    }

    case Tools.http_post(url,
           headers: [{"xi-api-key", api_key}, {"accept", accept_header(output_format)}],
           json: body,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: status, body: audio, headers: headers}} when status in 200..299 ->
        Logger.info("elevenlabs synthesis finished",
          provider: :elevenlabs,
          voice_id: voice_id,
          model_id: model_id,
          output_format: output_format,
          status: status,
          duration_ms: System.monotonic_time(:millisecond) - started_at,
          bytes: byte_size(audio || "")
        )

        {:ok,
         %Output{
           provider: :elevenlabs,
           format: response_format(output_format, headers),
           bytes: audio,
           metadata: %{voice_id: voice_id, model_id: model_id, output_format: output_format}
         }}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("elevenlabs synthesis http error",
          provider: :elevenlabs,
          voice_id: voice_id,
          model_id: model_id,
          status: status,
          duration_ms: System.monotonic_time(:millisecond) - started_at,
          body: inspect(body, limit: 8, printable_limit: 240)
        )

        {:error, {:elevenlabs_http_error, status, body}}

      {:error, reason} ->
        Logger.warning("elevenlabs synthesis failed",
          provider: :elevenlabs,
          voice_id: voice_id,
          model_id: model_id,
          duration_ms: System.monotonic_time(:millisecond) - started_at,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp content_type(headers) do
    headers
    |> Enum.find_value("audio/mpeg", fn {name, value} ->
      if String.downcase(to_string(name)) == "content-type", do: value
    end)
  end

  defp url(voice_id, output_format) do
    query = URI.encode_query(output_format: output_format)
    "#{@base_url}/v1/text-to-speech/#{voice_id}/stream?#{query}"
  end

  defp accept_header(output_format) do
    if String.starts_with?(output_format, "ulaw_") do
      "audio/basic"
    else
      "audio/mpeg"
    end
  end

  defp response_format(output_format, headers) do
    if String.starts_with?(output_format, "ulaw_") do
      PhoneAudio.telnyx_format()
    else
      content_type(headers)
    end
  end
end
