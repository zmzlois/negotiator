defmodule Negotiator.SileroVad.Native do
  @moduledoc """
  on-prem end-of-turn detector backed by the native silero vad host.
  """

  @behaviour Negotiator.SileroVad

  alias Negotiator.Env
  alias Negotiator.SileroVad.{Decision, Probabilistic}
  alias Negotiator.Voice.Ulaw

  require Logger

  @default_bin "native/silero_vad_eot/silero_vad_eot"

  @impl true
  def score(input) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, payload} <- payload(input),
         {:ok, decoded} <- run(payload) do
      Logger.debug("silero vad scored audio",
        call_id: input[:call_id],
        backend: decoded["backend"],
        model_loaded: decoded["model_loaded"],
        end_probability: decoded["end_probability"],
        should_reply: decoded["should_reply"],
        duration_ms: System.monotonic_time(:millisecond) - started_at
      )

      decision(decoded)
    else
      {:error, reason} ->
        Logger.warning("silero vad failed",
          call_id: input[:call_id],
          reason: inspect(reason),
          duration_ms: System.monotonic_time(:millisecond) - started_at
        )

        fallback(input, reason)
    end
  end

  @doc """
  returns true when the native binary exists and can be executed.
  """
  def available? do
    path = bin_path()
    File.regular?(path) and executable?(path)
  end

  @doc """
  returns the native binary path used by the adapter.
  """
  def bin_path do
    "SILERO_VAD_BIN"
    |> Env.get(@default_bin)
    |> expand_path()
  end

  defp payload(input) do
    with {:ok, audio} <- audio_bytes(input),
         {:ok, pcm16le, sample_rate} <- pcm16le(audio, input) do
      {:ok,
       %{
         sample_rate: sample_rate,
         frame_ms: integer_env("SILERO_VAD_FRAME_MS", 20),
         min_speech_ms: integer_env("SILERO_VAD_MIN_SPEECH_MS", 180),
         end_silence_ms: integer_env("SILERO_VAD_END_SILENCE_MS", 650),
         energy_threshold: float_env("SILERO_VAD_ENERGY_THRESHOLD", 0.012),
         speech_threshold: float_env("SILERO_VAD_SPEECH_THRESHOLD", 0.5),
         model_path: Env.get("SILERO_VAD_MODEL", default_model_path()),
         bytes_b64: Base.encode64(pcm16le)
       }}
    end
  end

  defp audio_bytes(input) do
    case Map.get(input, :audio) || Map.get(input, :audio_bytes) || Map.get(input, :bytes) do
      bytes when is_binary(bytes) and bytes != "" -> {:ok, bytes}
      _missing -> {:error, :silero_vad_no_audio}
    end
  end

  defp pcm16le(bytes, input) do
    sample_rate = Map.get(input, :sample_rate, 8_000)

    case audio_format(input) do
      :ulaw_8000 -> {:ok, Ulaw.decode_to_pcm16(bytes), 8_000}
      :pcm16le -> {:ok, bytes, sample_rate}
      other -> {:error, {:unsupported_audio_format, other}}
    end
  end

  defp audio_format(input) do
    input
    |> Map.get(:audio_format, :pcm16le)
    |> normalize_audio_format()
  end

  defp normalize_audio_format(format) when format in [:ulaw_8000, "ulaw_8000", "pcmu"] do
    :ulaw_8000
  end

  defp normalize_audio_format(format) when format in [:pcm16le, "pcm16le"], do: :pcm16le
  defp normalize_audio_format(format), do: format

  defp run(payload) do
    bin = bin_path()

    cond do
      available?() ->
        run_binary(bin, payload)

      required?() ->
        raise ArgumentError, "missing required silero vad binary: #{bin}"

      true ->
        {:error, {:silero_vad_binary_missing, bin}}
    end
  rescue
    error -> {:error, error}
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      {:error, _reason} -> false
    end
  end

  defp run_binary(bin, payload) do
    input = Jason.encode!(payload) <> "\n"

    port = Port.open({:spawn_executable, bin}, [:binary, :exit_status])
    Port.command(port, input)

    try do
      with {:ok, output} <- receive_port_output(port, "", timeout_ms()) do
        parse_output(output)
      end
    after
      close_port(port)
    end
  end

  defp receive_port_output(port, output, timeout_ms) do
    receive do
      {^port, {:data, data}} ->
        output = output <> data

        if String.contains?(output, "\n") do
          {:ok, output}
        else
          receive_port_output(port, output, timeout_ms)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:silero_vad_failed, status, String.trim(output)}}
    after
      timeout_ms -> {:error, {:silero_vad_timeout, timeout_ms}}
    end
  end

  defp parse_output(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil -> {:error, :silero_vad_empty_output}
      line -> decode_output(line)
    end
  end

  defp decode_output(line) do
    case Jason.decode(line) do
      {:ok, %{"error" => reason}} -> {:error, {:silero_vad_error, reason}}
      other -> other
    end
  end

  defp decision(decoded) do
    %Decision{
      end_probability: decoded |> number("end_probability", 0.0) |> clamp(),
      should_wait?: boolean(decoded, "should_wait", true),
      should_reply?: boolean(decoded, "should_reply", false),
      reason: reason(Map.get(decoded, "reason"))
    }
  end

  defp fallback(input, reason) do
    if required?() do
      raise ArgumentError, "silero vad turn detection failed: #{inspect(reason)}"
    end

    Logger.info("silero vad using probabilistic fallback",
      call_id: input[:call_id],
      reason: inspect(reason)
    )

    input
    |> Probabilistic.score()
    |> Map.put(:reason, fallback_reason(reason))
  end

  defp fallback_reason(:silero_vad_no_audio), do: :silero_vad_no_audio_fallback
  defp fallback_reason({:silero_vad_binary_missing, _path}), do: :silero_vad_binary_missing
  defp fallback_reason({:unsupported_audio_format, _format}), do: :silero_vad_unsupported_audio
  defp fallback_reason(_reason), do: :silero_vad_failed_fallback

  defp number(map, key, fallback) do
    case Map.get(map, key, fallback) do
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1
      value when is_binary(value) -> parse_float(value, fallback)
      _other -> fallback
    end
  end

  defp parse_float(value, fallback) do
    case Float.parse(value) do
      {float, _rest} -> float
      :error -> fallback
    end
  end

  defp boolean(map, key, fallback) do
    case Map.get(map, key, fallback) do
      value when is_boolean(value) -> value
      "true" -> true
      "false" -> false
      _other -> fallback
    end
  end

  defp reason("silero_model_not_configured_energy_fallback_end"), do: :likely_end_of_turn
  defp reason("silero_model_not_configured_energy_fallback_wait"), do: :wait_for_more_speech
  defp reason("silero_model_not_configured_energy_fallback_no_speech"), do: :wait_for_more_speech
  defp reason("silero_onnx_end"), do: :likely_end_of_turn
  defp reason("silero_onnx_wait"), do: :wait_for_more_speech
  defp reason("silero_onnx_no_speech"), do: :wait_for_more_speech
  defp reason("likely_end_of_turn"), do: :likely_end_of_turn
  defp reason("wait_for_more_speech"), do: :wait_for_more_speech
  defp reason(_other), do: :silero_vad_estimate

  defp integer_env(name, default) do
    case Integer.parse(Env.get(name, "")) do
      {integer, _rest} -> integer
      :error -> default
    end
  end

  defp float_env(name, default) do
    case Float.parse(Env.get(name, "")) do
      {float, _rest} -> float
      :error -> default
    end
  end

  defp expand_path(path) do
    case Path.type(path) do
      :absolute -> path
      _relative -> Path.expand(path, File.cwd!())
    end
  end

  defp required? do
    Env.get("SILERO_VAD_REQUIRED", "") in ["1", "true", "TRUE", "yes", "YES"] or
      Env.get("NEGOTIATOR_REQUIRE_LIVE_PROVIDERS", "0") in ["1", "true", "TRUE", "yes", "YES"]
  end

  defp timeout_ms, do: integer_env("SILERO_VAD_TIMEOUT_MS", 1_000)

  defp default_model_path, do: Path.expand("priv/models/silero_vad.onnx", File.cwd!())

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp clamp(value), do: value |> max(0.0) |> min(1.0)
end
