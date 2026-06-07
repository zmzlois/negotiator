defmodule Negotiator.Env do
  @moduledoc """
  reads provider configuration from environment variables.
  """

  @provider_env %{
    telnyx: [
      "TELNYX_API_KEY",
      "TELNYX_CONNECTION_ID",
      "TELNYX_PHONE_NUMBER",
      "TELNYX_PUBLIC_KEY",
      "PUBLIC_BASE_URL"
    ],
    openai_llm: [
      "OPENAI_API_KEY"
    ],
    elevenlabs_voice: [
      "ELEVENLABS_API_KEY",
      "ELEVENLABS_VOICE_ID"
    ],
    moss: [
      "MOSS_PROJECT_ID",
      "MOSS_PROJECT_KEY",
      "MOSS_INDEX_NAME"
    ],
    openai_identity: [],
    web_search: [
      "WEB_SEARCH_API_KEY"
    ],
    turn_detection: []
  }

  @provider_optional_env %{
    telnyx: [
      "TELNYX_TRANSCRIPTION_ENABLED",
      "TELNYX_TRANSCRIPTION_ENGINE",
      "TELNYX_TRANSCRIPTION_MODEL",
      "TELNYX_TRANSCRIPTION_LANGUAGE",
      "TELNYX_TRANSCRIPTION_TRACKS",
      "TELNYX_TRANSCRIPTION_ROLE",
      "TELNYX_TRANSCRIPTION_INTERIM_RESULTS",
      "NEGOTIATOR_PHONE_PARTICIPANT",
      "NEGOTIATOR_DEV_CONTROLS_ENABLED",
      "NEGOTIATOR_REQUIRE_LIVE_PROVIDERS",
      "TELNYX_STREAM_TRACK",
      "TELNYX_STREAM_CODEC",
      "TELNYX_STREAM_BIDIRECTIONAL_MODE",
      "TELNYX_STREAM_BIDIRECTIONAL_CODEC",
      "TELNYX_STREAM_BIDIRECTIONAL_TARGET_LEGS",
      "TELNYX_STREAM_BIDIRECTIONAL_SAMPLING_RATE"
    ],
    openai_llm: [
      "OPENAI_BASE_URL",
      "OPENAI_CHAT_MODEL",
      "NEGOTIATOR_DEV_COACH_VOICE",
      "NEGOTIATOR_DEV_INVESTOR_VOICE"
    ],
    elevenlabs_voice: [
      "ELEVENLABS_MODEL_ID",
      "ELEVENLABS_OUTPUT_FORMAT",
      "ELEVENLABS_INVESTOR_VOICE_ID",
      "NEGOTIATOR_DEV_VOICE"
    ],
    moss: [
      "MOSS_API_KEY",
      "MOSS_ALPHA",
      "MOSS_AUTO_REFRESH",
      "MOSS_BASE_URL",
      "MOSS_TRANSCRIPT_INDEXING_ENABLED"
    ],
    openai_identity: [
      "OPENAI_IDENTITY_MODEL",
      "OPENAI_BASE_URL"
    ],
    turn_detection: [
      "NEGOTIATOR_TURN_DETECTION",
      "SILERO_VAD_BIN",
      "SILERO_VAD_MODEL",
      "SILERO_VAD_REQUIRED",
      "SILERO_VAD_FRAME_MS",
      "SILERO_VAD_MIN_SPEECH_MS",
      "SILERO_VAD_CANDIDATE_PAUSE_MS",
      "SILERO_VAD_END_SILENCE_MS",
      "SILERO_VAD_SPEECH_THRESHOLD",
      "SILERO_VAD_ENERGY_THRESHOLD",
      "SILERO_VAD_TIMEOUT_MS"
    ],
    audio: ["FFMPEG_BIN"]
  }

  @dotenv_aliases [
    {"PHONE_NUMBER", "TELNYX_PHONE_NUMBER"},
    {"PUBLIC_URL", "PUBLIC_BASE_URL"},
    {"NGROK_URL", "PUBLIC_BASE_URL"},
    {"ELEVENLABS_VOICE", "ELEVENLABS_VOICE_ID"},
    {"SMALL_TALK_VOICE_ID", "ELEVENLABS_VOICE_ID"},
    {"FOUNDER_VOICE_ID", "ELEVENLABS_VOICE_ID"},
    {"AGENT_VOICE_ID", "ELEVENLABS_VOICE_ID"},
    {"INVESTOR_VOICE_ID", "ELEVENLABS_INVESTOR_VOICE_ID"},
    {"MOSS_INDEX", "MOSS_INDEX_NAME"}
  ]

  @doc """
  returns the required env vars for a provider.
  """
  def required(provider), do: Map.fetch!(@provider_env, provider)

  @doc """
  returns optional env vars for a provider.
  """
  def optional(provider), do: Map.get(@provider_optional_env, provider, [])

  @doc """
  checks required provider env vars without leaking secret values.
  """
  def check(providers \\ Map.keys(@provider_env)) do
    providers
    |> Enum.flat_map(fn provider ->
      Enum.map(required(provider), fn name ->
        %{
          provider: provider,
          name: name,
          present?: present?(name),
          secret?: secret?(name)
        }
      end)
    end)
  end

  @doc """
  fetches a required env var.
  """
  def fetch!(name) do
    case System.fetch_env(name) do
      {:ok, value} when value != "" -> value
      _missing -> raise ArgumentError, "missing required env var: #{name}"
    end
  end

  @doc """
  fetches an optional env var.
  """
  def get(name, default \\ nil), do: System.get_env(name, default)

  @doc """
  loads local dotenv files without printing or returning secret values.
  """
  def load_dotenv(paths \\ default_dotenv_paths(), opts \\ []) do
    paths = paths |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))
    override? = Keyword.get(opts, :override?, false)

    loaded =
      paths
      |> Enum.flat_map(fn path ->
        case load_dotenv_file(path, override?) do
          {:ok, entry} -> [entry]
          {:missing, _path} -> []
        end
      end)

    %{
      loaded: loaded,
      aliases: apply_dotenv_aliases(override?),
      defaults: apply_runtime_defaults()
    }
  end

  @doc """
  loads dotenv files once for the current process without printing secrets.
  """
  def load_runtime_dotenv(paths \\ default_dotenv_paths()) do
    if System.get_env("NEGOTIATOR_DOTENV_LOADED") == "1" do
      %{loaded: [], aliases: [], defaults: [], already_loaded?: true}
    else
      report = load_dotenv(paths)
      System.put_env("NEGOTIATOR_DOTENV_LOADED", "1")
      Map.put(report, :already_loaded?, false)
    end
  end

  @doc """
  returns the local http port.
  """
  def port do
    "PORT"
    |> get("4000")
    |> String.to_integer()
  end

  @doc """
  returns the public websocket url for telnyx media streaming.
  """
  def media_stream_url do
    "#{public_ws_base()}/telnyx/media-streaming"
  end

  @doc """
  returns the participant-specific media websocket url for a live telnyx call.
  """
  def media_stream_url(call_control_id, participant \\ nil) do
    participant = participant || get("NEGOTIATOR_PHONE_PARTICIPANT", "founder")

    "#{public_ws_base()}/media/#{path_segment(call_control_id)}/#{path_segment(participant)}"
  end

  defp public_ws_base do
    base_url =
      "PUBLIC_BASE_URL"
      |> fetch!()
      |> String.replace_prefix("https://", "wss://")
      |> String.replace_prefix("http://", "ws://")
      |> String.trim_trailing("/")

    base_url
  end

  defp path_segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  @doc """
  returns true if the env var is set and non-empty.
  """
  def present?(name), do: match?({:ok, value} when value != "", System.fetch_env(name))

  defp secret?(name), do: String.contains?(name, ["KEY", "SECRET", "TOKEN"])

  defp default_dotenv_paths do
    case System.get_env("NEGOTIATOR_ENV_FILE") do
      value when is_binary(value) and value != "" ->
        String.split(value, [":", ","], trim: true)

      _missing ->
        [".env", ".env.local", "../sf-voice-core/.env", "../sf-voice-core/.env.local"]
    end
  end

  defp load_dotenv_file(path, override?) do
    case File.read(path) do
      {:ok, body} ->
        keys =
          body
          |> String.split("\n")
          |> Enum.flat_map(&load_dotenv_line(&1, override?))

        {:ok, %{path: path, keys: keys}}

      {:error, :enoent} ->
        {:missing, path}

      {:error, reason} ->
        raise "could not read dotenv file #{path}: #{inspect(reason)}"
    end
  end

  defp load_dotenv_line(line, override?) do
    case parse_dotenv_line(line) do
      {:ok, name, value} ->
        if override? or not present?(name), do: System.put_env(name, value)
        [name]

      :skip ->
        []
    end
  end

  defp parse_dotenv_line(line) do
    line = String.trim(line)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        :skip

      true ->
        line
        |> String.replace_prefix("export ", "")
        |> split_dotenv_assignment()
    end
  end

  defp split_dotenv_assignment(line) do
    case String.split(line, "=", parts: 2) do
      [name, value] ->
        name = String.trim(name)

        if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name) do
          {:ok, name, clean_dotenv_value(value)}
        else
          :skip
        end

      _other ->
        :skip
    end
  end

  defp clean_dotenv_value(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value
        |> String.trim_leading("\"")
        |> String.trim_trailing("\"")
        |> String.replace("\\n", "\n")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value
        |> String.trim_leading("'")
        |> String.trim_trailing("'")

      true ->
        value
    end
  end

  defp apply_dotenv_aliases(override?) do
    @dotenv_aliases
    |> Enum.flat_map(fn {source, target} ->
      with {:ok, value} when value != "" <- System.fetch_env(source),
           false <- not override? and present?(target) do
        System.put_env(target, value)
        [%{source: source, target: target}]
      else
        _other -> []
      end
    end)
  end

  defp apply_runtime_defaults do
    []
    |> put_default_moss_index()
  end

  defp put_default_moss_index(defaults) do
    cond do
      present?("MOSS_INDEX_NAME") ->
        defaults

      present?("MOSS_PROJECT_ID") and (present?("MOSS_PROJECT_KEY") or present?("MOSS_API_KEY")) ->
        System.put_env("MOSS_INDEX_NAME", "demo-voice_ai_call_snippets")
        [%{name: "MOSS_INDEX_NAME", value: "demo-voice_ai_call_snippets"} | defaults]

      true ->
        defaults
    end
  end
end
