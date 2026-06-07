defmodule Negotiator.Logging do
  @moduledoc """
  small structured logging helpers for live call debugging.
  """

  require Logger

  @debug_call_events MapSet.new([
                       :media_frame_received,
                       :speech_partial
                     ])
  @debug_provider_jobs MapSet.new([])

  @doc """
  applies runtime log level settings from env.
  """
  def configure_from_env do
    case configured_level() do
      nil -> :ok
      level -> Logger.configure(level: level)
    end

    Logger.metadata(app: :negotiator)
  end

  @doc """
  logs one event from the call session event log.
  """
  def call_event(call_id, sequence, mode, :speech_final, payload) do
    transcript_turn(call_id, payload[:role], payload[:room], payload[:text],
      sequence: sequence,
      mode: mode,
      event: :speech_final
    )
  end

  def call_event(call_id, sequence, mode, :small_talk_agent_spoke, payload) do
    transcript_turn(call_id, :small_talk_agent, payload[:room], payload[:text],
      sequence: sequence,
      mode: mode,
      event: :small_talk_agent_spoke
    )
  end

  def call_event(call_id, sequence, mode, :probabilistic_turn_committed, payload) do
    turn_decision(call_id, :probabilistic_text, Map.put(payload, :should_reply, true),
      sequence: sequence,
      mode: mode,
      event: :probabilistic_turn_committed
    )
  end

  def call_event(call_id, sequence, mode, type, payload) do
    level = if MapSet.member?(@debug_call_events, type), do: :debug, else: :info

    Logger.log(level, "call event #{type}",
      call_id: call_id,
      sequence: sequence,
      mode: mode,
      event: type,
      payload: compact_payload(payload)
    )
  end

  @doc """
  logs one final transcript turn with enough text to debug live calls.
  """
  def transcript_turn(call_id, role, room, text, metadata \\ []) do
    preview = compact_text(text)

    Logger.info(
      "transcript turn role=#{role} room=#{room} text=#{inspect(preview)}",
      [
        call_id: call_id,
        role: role,
        room: room,
        text_chars: text_length(text),
        text_preview: preview
      ] ++ metadata
    )
  end

  @doc """
  logs one llm request or response without leaking credentials or full prompts.
  """
  def llm_io(status, provider, task, metadata \\ []) do
    Logger.log(
      provider_call_level(status),
      llm_message(status, provider, task, metadata),
      [service: provider, provider: provider, task: task, status: status] ++ metadata
    )
  end

  @doc """
  logs turn decisions at info only when the system is about to commit a turn.
  """
  def turn_decision(call_id, source, decision, metadata \\ []) do
    should_reply? = truthy?(decision[:should_reply] || decision[:should_reply?])
    action = if should_reply?, do: :commit, else: :wait
    level = if should_reply?, do: :info, else: :debug

    Logger.log(
      level,
      "turn decision source=#{source} action=#{action} role=#{decision[:role]} p=#{decision[:end_probability]} reason=#{decision[:reason]}",
      [
        call_id: call_id,
        source: source,
        action: action,
        role: decision[:role],
        end_probability: decision[:end_probability],
        reason: decision[:reason],
        text_preview: compact_text(decision[:text])
      ] ++ metadata
    )
  end

  @doc """
  logs a provider job lifecycle event.
  """
  def provider_job(status, call_id, kind, metadata \\ []) do
    level =
      if MapSet.member?(@debug_provider_jobs, kind),
        do: :debug,
        else: provider_job_level(status)

    Logger.log(
      level,
      provider_job_message(status, kind, metadata),
      [call_id: call_id, provider_job: kind, status: status] ++ metadata
    )
  end

  @doc """
  logs an external provider call without leaking secrets or full payloads.
  """
  def provider_call(status, provider, operation, metadata \\ []) do
    Logger.log(
      provider_call_level(status),
      "provider #{status} #{provider}.#{operation}" <>
        metadata_message(metadata, [:model, :duration_ms, :http_status, :reason]),
      [provider: provider, operation: operation, status: status] ++ metadata
    )
  end

  def compact_text(value) when is_binary(value) do
    if String.valid?(value), do: truncate(value), else: "<#{byte_size(value)} bytes>"
  end

  def compact_text(nil), do: ""
  def compact_text(value), do: value |> inspect(limit: 8, printable_limit: 240) |> truncate()

  def compact_inspect(value) do
    value
    |> compact_value()
    |> inspect(limit: 8, printable_limit: 240)
    |> truncate()
  end

  def llm_text(value) when is_binary(value) do
    if String.valid?(value), do: truncate_llm(value), else: "<#{byte_size(value)} bytes>"
  end

  def llm_text(nil), do: ""
  def llm_text(value), do: value |> inspect(limit: 20, printable_limit: 4_000) |> truncate_llm()

  defp configured_level do
    level =
      System.get_env("NEGOTIATOR_LOG_LEVEL") ||
        case System.get_env("LOG") do
          value when value in ["1", "true", "TRUE", "debug", "DEBUG"] -> "debug"
          value when value in ["info", "INFO"] -> "info"
          value when value in ["warn", "warning", "WARN", "WARNING"] -> "warning"
          value when value in ["error", "ERROR"] -> "error"
          _other -> nil
        end

    case level && String.downcase(level) do
      "debug" -> :debug
      "info" -> :info
      "warn" -> :warning
      "warning" -> :warning
      "error" -> :error
      _other -> nil
    end
  end

  defp provider_job_level(:failed), do: :warning
  defp provider_job_level(:error), do: :warning
  defp provider_job_level(_status), do: :info

  defp provider_call_level(:failed), do: :warning
  defp provider_call_level(:error), do: :warning
  defp provider_call_level(:http_error), do: :warning
  defp provider_call_level(_status), do: :info

  defp compact_payload(payload) do
    payload
    |> compact_value()
    |> inspect(limit: 12, printable_limit: 240)
  end

  defp compact_value(%_{} = value), do: value |> Map.from_struct() |> compact_value()

  defp compact_value(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {key, compact_value(value)} end)
  end

  defp compact_value(value) when is_list(value), do: Enum.map(value, &compact_value/1)

  defp compact_value(value) when is_binary(value) do
    if String.valid?(value) do
      truncate(value)
    else
      "<#{byte_size(value)} bytes>"
    end
  end

  defp compact_value(value), do: value

  defp llm_message(status, provider, task, metadata) do
    model = metadata |> Keyword.get(:model) |> format_optional_kv(" model=")
    host = metadata |> Keyword.get(:service_host) |> format_optional_kv(" host=")
    duration = metadata |> Keyword.get(:duration_ms) |> format_optional_kv(" duration_ms=")
    http_status = metadata |> Keyword.get(:http_status) |> format_optional_kv(" http_status=")

    system_prompt =
      metadata |> Keyword.get(:system_prompt) |> format_optional_preview(" system_prompt=")

    context = metadata |> Keyword.get(:context) |> format_optional_preview(" context=")
    input = metadata |> Keyword.get(:input_preview) |> format_optional_preview(" input=")
    output = metadata |> Keyword.get(:output_preview) |> format_optional_preview(" output=")
    reason = metadata |> Keyword.get(:reason) |> format_optional_preview(" reason=")

    "llm #{status} provider=#{provider} task=#{task}" <>
      model <>
      host <> duration <> http_status <> system_prompt <> context <> input <> output <> reason
  end

  defp provider_job_message(status, kind, metadata) do
    "provider job #{status} #{kind}" <>
      metadata_message(metadata, [
        :llm_service,
        :retrieval_service,
        :voice_service,
        :coach_voice_service,
        :investor_voice_service,
        :research_service,
        :turn_detection_service,
        :source,
        :checkpoint,
        :duration_ms,
        :reason
      ])
  end

  defp metadata_message(metadata, keys) do
    keys
    |> Enum.flat_map(fn key ->
      case Keyword.fetch(metadata, key) do
        {:ok, nil} -> []
        {:ok, ""} -> []
        {:ok, value} -> [" #{key}=#{format_metadata_value(value)}"]
        :error -> []
      end
    end)
    |> Enum.join()
  end

  defp format_metadata_value(value) when is_atom(value), do: to_string(value)
  defp format_metadata_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_metadata_value(value) when is_float(value), do: Float.to_string(value)
  defp format_metadata_value(value) when is_binary(value), do: inspect(compact_text(value))
  defp format_metadata_value(value), do: compact_inspect(value)

  defp format_optional_kv(nil, _prefix), do: ""
  defp format_optional_kv(value, prefix), do: prefix <> to_string(value)

  defp format_optional_preview(nil, _prefix), do: ""
  defp format_optional_preview("", _prefix), do: ""
  defp format_optional_preview(value, prefix), do: prefix <> inspect(value)

  defp text_length(value) when is_binary(value) do
    if String.valid?(value), do: String.length(value), else: byte_size(value)
  end

  defp text_length(_value), do: 0

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp truncate(value) do
    if String.length(value) > 180 do
      String.slice(value, 0, 180) <> "..."
    else
      value
    end
  end

  defp truncate_llm(value) do
    if full_llm_logs?() do
      value
    else
      limit = llm_log_limit()

      if String.length(value) > limit do
        String.slice(value, 0, limit) <> "..."
      else
        value
      end
    end
  end

  defp full_llm_logs? do
    System.get_env("NEGOTIATOR_LLM_LOG_FULL") in ["1", "true", "TRUE", "yes", "YES"]
  end

  defp llm_log_limit do
    case Integer.parse(System.get_env("NEGOTIATOR_LLM_LOG_CHARS") || "") do
      {limit, _rest} when limit > 0 -> limit
      _other -> 1_200
    end
  end
end
