defmodule Negotiator.LLM.Speech.ElevenLabsVoices do
  @moduledoc """
  lists elevenlabs voices so local setup can choose a voice id.
  """

  alias Negotiator.{Env, Tools}

  @base_url "https://api.elevenlabs.io"

  @doc """
  returns available voices from elevenlabs.
  """
  def list(opts \\ []) do
    api_key = Keyword.get_lazy(opts, :api_key, fn -> Env.fetch!("ELEVENLABS_API_KEY") end)
    base_url = Keyword.get(opts, :base_url, Env.get("ELEVENLABS_BASE_URL", @base_url))

    query =
      opts
      |> Keyword.take([:search, :category, :voice_type])
      |> Keyword.put(:page_size, Keyword.get(opts, :page_size, 20))
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    case Tools.http_get("#{base_url}/v2/voices",
           headers: [{"xi-api-key", api_key}],
           params: query,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        normalize_response(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:elevenlabs_http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  normalizes the elevenlabs voices response into safe display fields.
  """
  def normalize_response(%{"voices" => voices}) when is_list(voices) do
    {:ok, Enum.map(voices, &voice_summary/1)}
  end

  def normalize_response(_body), do: {:error, :invalid_voices_response}

  defp voice_summary(voice) when is_map(voice) do
    %{
      voice_id: Map.get(voice, "voice_id"),
      name: Map.get(voice, "name"),
      category: Map.get(voice, "category"),
      description: Map.get(voice, "description")
    }
  end
end
