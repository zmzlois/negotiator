defmodule NegotiatorWeb.DevCallControls do
  @moduledoc """
  local http controls for replacing human call roles during development.
  """

  alias Negotiator.{CallSession, CallSupervisor, Env, Transcript}
  alias Negotiator.Telephony.DevMediaSink
  alias Negotiator.Telephony.Telnyx.MediaStream

  @doc """
  returns true when local development call controls are enabled.
  """
  def enabled? do
    Env.get("NEGOTIATOR_DEV_CONTROLS_ENABLED", "0") in ["1", "true", "TRUE", "yes", "YES"]
  end

  @doc """
  records a final speech turn for a human role.
  """
  def say(call_id, params) do
    with {:ok, call_session} <- call_session(call_id),
         {:ok, role} <- role(params),
         {:ok, text} <- text(params),
         {:ok, snapshot} <- CallSession.say(call_session, role, text) do
      {:ok, snapshot}
    end
  end

  @doc """
  records a partial speech update for a human role.
  """
  def partial(call_id, params) do
    with {:ok, call_session} <- call_session(call_id),
         {:ok, role} <- role(params),
         {:ok, text} <- text(params),
         {:ok, snapshot} <-
           CallSession.partial(call_session, role, text,
             silence_ms: silence_ms(params),
             source: :http_dev_control
           ) do
      {:ok, snapshot}
    end
  end

  @doc """
  injects a telnyx-style transcription event into the call session.
  """
  def transcription(call_id, params) do
    with {:ok, call_session} <- call_session(call_id),
         {:ok, role} <- role(params),
         {:ok, text} <- text(params),
         {:ok, snapshot} <-
           CallSession.handle_event(
             call_session,
             Negotiator.CallEvent.transcription(text, final?(params), %{
               role: role,
               confidence: confidence(params),
               silence_ms: silence_ms(params),
               source: :http_dev_transcription
             })
           ) do
      {:ok, snapshot}
    end
  end

  @doc """
  injects a telnyx-style media frame into the call session.
  """
  def media_frame(call_id, params) do
    with {:ok, call_session} <- call_session(call_id),
         {:ok, bytes, metadata} <- media_payload(params),
         {:ok, snapshot} <- CallSession.media_frame(call_session, bytes, metadata) do
      {:ok, snapshot}
    end
  end

  @doc """
  sends a dtmf digit into the call session.
  """
  def dtmf(call_id, params) do
    with {:ok, call_session} <- call_session(call_id),
         {:ok, digit} <- digit(params) do
      case CallSession.press_digit(call_session, digit) do
        {:ok, snapshot} -> {:ok, snapshot}
        {:ignored, snapshot} -> {:ok, snapshot}
      end
    end
  end

  @doc """
  returns the founder to the main conversation.
  """
  def resume(call_id) do
    with {:ok, call_session} <- call_session(call_id),
         {:ok, snapshot} <- CallSession.resume_founder(call_session) do
      {:ok, snapshot}
    end
  end

  @doc """
  connects a local media sink as a phone participant.
  """
  def connect_media(call_id, participant) do
    DevMediaSink.connect(call_id, participant)
  end

  @doc """
  returns captured local media sink events.
  """
  def media_events(call_id, participant) do
    DevMediaSink.events(call_id, participant)
  end

  @doc """
  clears captured local media sink events.
  """
  def clear_media(call_id, participant) do
    DevMediaSink.clear(call_id, participant)
  end

  defp call_session(call_id) do
    CallSupervisor.start_or_get_call(call_id: call_id)
  end

  defp role(params) do
    value = Map.get(params, "role") || Map.get(params, :role)

    case Transcript.normalize_role(value || "founder") do
      role when role in [:founder, :investor] -> {:ok, role}
      role -> {:error, {:invalid_role, role}}
    end
  rescue
    ArgumentError -> {:error, :invalid_role}
  end

  defp text(params) do
    params
    |> Map.get("text", Map.get(params, :text))
    |> case do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_text}, else: {:ok, value}

      _missing ->
        {:error, :missing_text}
    end
  end

  defp digit(params) do
    params
    |> Map.get("digit", Map.get(params, :digit))
    |> case do
      value when is_binary(value) and byte_size(value) == 1 -> {:ok, value}
      value when is_integer(value) and value in 0..9 -> {:ok, Integer.to_string(value)}
      _invalid -> {:error, :invalid_digit}
    end
  end

  defp silence_ms(params) do
    params
    |> Map.get("silence_ms", Map.get(params, :silence_ms, 0))
    |> parse_integer(0)
  end

  defp final?(params) do
    Map.get(params, "final", Map.get(params, "final?", Map.get(params, :final, false))) in [
      true,
      "true",
      "TRUE",
      1,
      "1"
    ]
  end

  defp confidence(params) do
    params
    |> Map.get("confidence", Map.get(params, :confidence))
    |> parse_float()
  end

  defp parse_float(nil), do: nil
  defp parse_float(value) when is_number(value), do: value

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _rest} -> float
      :error -> nil
    end
  end

  defp parse_float(_value), do: nil

  defp media_payload(params) do
    payload =
      Map.get(params, "payload") ||
        get_in(params, ["media", "payload"]) ||
        Map.get(params, :payload)

    case Base.decode64(to_string(payload || "")) do
      {:ok, bytes} when bytes != "" ->
        raw_track = Map.get(params, "track") || get_in(params, ["media", "track"])
        participant = Map.get(params, "participant") || Map.get(params, :participant) || "founder"

        {:ok, bytes,
         %{
           track: MediaStream.normalize_track(raw_track),
           raw_track: raw_track,
           timestamp: Map.get(params, "timestamp") || get_in(params, ["media", "timestamp"]),
           participant: participant,
           commit?: truthy?(Map.get(params, "commit", Map.get(params, "commit?", false))),
           force_transcribe?: truthy?(Map.get(params, "force_transcribe", false)),
           local_text: Map.get(params, "local_text")
         }}

      _invalid ->
        {:error, :invalid_media_payload}
    end
  end

  defp truthy?(value), do: value in [true, "true", "TRUE", 1, "1", "yes", "YES"]

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> default
    end
  end

  defp parse_integer(_value, default), do: default
end
