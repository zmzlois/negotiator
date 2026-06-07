defmodule Negotiator.Telephony.TelnyxWebhook do
  @moduledoc """
  handles telnyx call-control webhook events.
  """

  alias Negotiator.{CallEvent, CallSession, CallSupervisor, Env, Logging, Telephony.Telnyx, Tools}

  require Logger

  def handle(params, opts \\ [])

  def handle(%{"data" => %{"event_type" => event_type, "payload" => payload}}, opts) do
    telephony = Keyword.get(opts, :telephony, configured_telephony())
    call_id = payload && payload["call_control_id"]

    Logger.info("telnyx webhook received",
      call_id: call_id,
      event_type: event_type,
      from: payload && payload["from"],
      to: payload && payload["to"]
    )

    payload = payload || %{}

    case investor_outbound_context(payload) do
      {:ok, context} -> handle_investor_outbound_event(event_type, payload, telephony, context)
      :none -> handle_event(event_type, payload, telephony)
    end
  end

  def handle(params, _opts) do
    Logger.warning("telnyx webhook ignored malformed payload", payload: inspect(params, limit: 8))
    :ok
  end

  defp handle_event("call.initiated", %{"call_control_id" => call_id} = payload, telephony) do
    with {:ok, call_session} <- CallSupervisor.start_or_get_call(call_id: call_id),
         {:ok, _snapshot} <-
           CallSession.handle_event(
             call_session,
             CallEvent.provider(:telnyx_webhook, :telnyx_call_initiated, payload)
           ) do
      answer_call(telephony, call_id)
    end

    :ok
  end

  defp handle_event("call.answered", %{"call_control_id" => call_id} = payload, telephony) do
    with {:ok, call_session} <- CallSupervisor.start_or_get_call(call_id: call_id),
         {:ok, _snapshot} <-
           CallSession.handle_event(
             call_session,
             CallEvent.provider(:telnyx_webhook, :telnyx_call_answered, payload)
           ) do
      start_streaming(telephony, call_id)
      start_transcription(telephony, call_id)
    end

    :ok
  end

  defp handle_event("call.transcription", %{"call_control_id" => call_id} = payload, _telephony) do
    transcription = payload["transcription_data"] || %{}
    text = transcription["transcript"] || ""
    final? = transcription["is_final"] in [true, "true", "TRUE", 1, "1"]

    Logger.info("telnyx transcription received",
      call_id: call_id,
      final?: final?,
      confidence: transcription["confidence"],
      text_chars: String.length(text),
      text_preview: Logging.llm_text(text)
    )

    with pid when is_pid(pid) <- CallSupervisor.lookup_call(call_id),
         true <- String.trim(text) != "" do
      CallSession.handle_event(
        pid,
        CallEvent.transcription(text, final?, %{
          confidence: transcription["confidence"],
          call_leg_id: payload["call_leg_id"],
          call_session_id: payload["call_session_id"],
          connection_id: payload["connection_id"],
          client_state: payload["client_state"],
          role: transcription_role()
        })
      )
    else
      _missing_or_empty -> :ok
    end

    :ok
  end

  defp handle_event("streaming.started", %{"call_control_id" => call_id} = payload, _telephony) do
    with {:ok, call_session} <- CallSupervisor.start_or_get_call(call_id: call_id) do
      CallSession.handle_event(
        call_session,
        CallEvent.provider(:telnyx_webhook, :telnyx_streaming_started, payload)
      )
    end

    :ok
  end

  defp handle_event("streaming.stopped", %{"call_control_id" => call_id} = payload, _telephony) do
    case CallSupervisor.lookup_call(call_id) do
      pid when is_pid(pid) ->
        CallSession.handle_event(
          pid,
          CallEvent.provider(:telnyx_webhook, :telnyx_streaming_stopped, payload)
        )

      nil ->
        :ok
    end

    :ok
  end

  defp handle_event(
         "call.dtmf.received",
         %{"call_control_id" => call_id, "digit" => digit},
         _telephony
       ) do
    with {:ok, call_session} <- CallSupervisor.start_or_get_call(call_id: call_id) do
      CallSession.handle_event(call_session, CallEvent.dtmf(digit))
    end

    :ok
  end

  defp handle_event("call.hangup", %{"call_control_id" => call_id} = payload, _telephony) do
    Logger.info("telnyx call hangup",
      call_id: call_id,
      hangup_cause: payload["hangup_cause"],
      hangup_source: payload["hangup_source"]
    )

    case CallSupervisor.lookup_call(call_id) do
      pid when is_pid(pid) ->
        CallSession.handle_event(
          pid,
          CallEvent.provider(:telnyx_webhook, :telnyx_call_hangup, payload)
        )

        CallSession.handle_event(
          pid,
          CallEvent.end_call(payload["hangup_cause"] || :telnyx_hangup)
        )

        CallSupervisor.stop_call(call_id)

      nil ->
        :ok
    end

    :ok
  end

  defp handle_event(event_type, payload, _telephony) do
    Logger.debug("ignored telnyx webhook event #{event_type}: #{inspect(payload)}")
    :ok
  end

  defp handle_investor_outbound_event(
         "call.initiated",
         %{"call_control_id" => investor_call_id} = payload,
         _telephony,
         context
       ) do
    with pid when is_pid(pid) <- CallSupervisor.lookup_call(context.parent_call_control_id) do
      CallSession.handle_event(
        pid,
        CallEvent.provider(:telnyx_webhook, :investor_dial_initiated, %{
          investor_call_control_id: investor_call_id,
          payload: payload
        })
      )
    end

    :ok
  end

  defp handle_investor_outbound_event(
         "call.answered",
         %{"call_control_id" => investor_call_id} = payload,
         telephony,
         context
       ) do
    with pid when is_pid(pid) <- CallSupervisor.lookup_call(context.parent_call_control_id) do
      CallSession.handle_event(
        pid,
        CallEvent.provider(:telnyx_webhook, :investor_call_answered, %{
          investor_call_control_id: investor_call_id,
          investor_identity: context.investor_identity,
          payload: payload
        })
      )

      start_streaming(telephony, investor_call_id,
        participant: :investor,
        client_state: investor_client_state(context)
      )

      start_transcription(telephony, investor_call_id,
        client_state: investor_client_state(context),
        transcription_tracks: "inbound"
      )

      bridge_investor_call(telephony, context.parent_call_control_id, investor_call_id, pid)
    end

    :ok
  end

  defp handle_investor_outbound_event(
         "call.transcription",
         %{"call_control_id" => investor_call_id} = payload,
         _telephony,
         context
       ) do
    transcription = payload["transcription_data"] || %{}
    text = transcription["transcript"] || ""
    final? = transcription["is_final"] in [true, "true", "TRUE", 1, "1"]

    Logger.info("telnyx investor transcription received",
      call_id: context.parent_call_control_id,
      investor_call_id: investor_call_id,
      final?: final?,
      confidence: transcription["confidence"],
      text_chars: String.length(text),
      text_preview: Logging.llm_text(text)
    )

    with pid when is_pid(pid) <- CallSupervisor.lookup_call(context.parent_call_control_id),
         true <- String.trim(text) != "" do
      CallSession.handle_event(
        pid,
        CallEvent.transcription(text, final?, %{
          confidence: transcription["confidence"],
          call_leg_id: payload["call_leg_id"],
          call_session_id: payload["call_session_id"],
          connection_id: payload["connection_id"],
          client_state: payload["client_state"],
          investor_call_control_id: investor_call_id,
          role: :investor
        })
      )
    else
      _missing_or_empty -> :ok
    end

    :ok
  end

  defp handle_investor_outbound_event(
         "call.bridged",
         %{"call_control_id" => investor_call_id} = payload,
         _telephony,
         context
       ) do
    with pid when is_pid(pid) <- CallSupervisor.lookup_call(context.parent_call_control_id) do
      CallSession.handle_event(
        pid,
        CallEvent.provider(:telnyx_webhook, :investor_bridged, %{
          investor_call_control_id: investor_call_id,
          payload: payload
        })
      )
    end

    :ok
  end

  defp handle_investor_outbound_event(
         "call.hangup",
         %{"call_control_id" => investor_call_id} = payload,
         _telephony,
         context
       ) do
    with pid when is_pid(pid) <- CallSupervisor.lookup_call(context.parent_call_control_id) do
      CallSession.handle_event(
        pid,
        CallEvent.provider(:telnyx_webhook, :investor_call_hangup, %{
          investor_call_control_id: investor_call_id,
          payload: payload
        })
      )
    end

    :ok
  end

  defp handle_investor_outbound_event(event_type, payload, _telephony, context) do
    Logger.debug("ignored investor outbound webhook #{event_type}",
      parent_call_control_id: context.parent_call_control_id,
      payload: inspect(payload, limit: 8)
    )

    :ok
  end

  defp configured_telephony do
    Application.get_env(:negotiator, :telnyx_client, Telnyx)
  end

  defp transcription_role do
    default_role = Env.get("NEGOTIATOR_PHONE_PARTICIPANT", "founder")

    case Env.get("TELNYX_TRANSCRIPTION_ROLE", default_role) |> String.downcase() do
      "investor" -> :investor
      _other -> :founder
    end
  end

  defp answer_call(telephony, call_id) do
    Logger.info("answering telnyx call", call_id: call_id)

    case Tools.answer_call(telephony, call_id) do
      {:ok, _response} ->
        Logger.info("telnyx call answered", call_id: call_id)
        :ok

      :ok ->
        Logger.info("telnyx call answered", call_id: call_id)
        :ok

      {:error, reason} ->
        Logger.warning("telnyx answer failed: #{inspect(reason)}")

      other ->
        Logger.debug("telnyx answer returned: #{inspect(other)}")
    end
  end

  defp start_streaming(telephony, call_id, opts \\ []) do
    Logger.info("starting telnyx media streaming", call_id: call_id)

    case Tools.start_streaming(telephony, call_id, opts) do
      {:ok, _response} ->
        Logger.info("telnyx media streaming started", call_id: call_id)
        :ok

      :ok ->
        Logger.info("telnyx media streaming started", call_id: call_id)
        :ok

      {:error, reason} ->
        Logger.warning("telnyx streaming_start failed: #{inspect(reason)}")

      other ->
        Logger.debug("telnyx streaming_start returned: #{inspect(other)}")
    end
  end

  defp start_transcription(telephony, call_id, opts \\ []) do
    Logger.info("starting telnyx transcription", call_id: call_id)

    case Tools.start_transcription(telephony, call_id, opts) do
      {:ok, _response} ->
        Logger.info("telnyx transcription started", call_id: call_id)
        :ok

      :ok ->
        Logger.info("telnyx transcription started", call_id: call_id)
        :ok

      :disabled ->
        Logger.info("telnyx transcription disabled", call_id: call_id)
        :ok

      {:error, reason} ->
        Logger.warning("telnyx transcription_start failed: #{inspect(reason)}")

      other ->
        Logger.debug("telnyx transcription_start returned: #{inspect(other)}")
    end
  end

  defp bridge_investor_call(telephony, parent_call_id, investor_call_id, call_session) do
    Logger.info("bridging investor call",
      call_id: parent_call_id,
      investor_call_id: investor_call_id
    )

    case Tools.bridge_calls(telephony, parent_call_id, investor_call_id) do
      {:ok, _response} ->
        record_bridge_requested(call_session, investor_call_id)

      :ok ->
        record_bridge_requested(call_session, investor_call_id)

      {:error, reason} ->
        Logger.warning("telnyx bridge failed: #{inspect(reason)}")

      other ->
        Logger.debug("telnyx bridge returned: #{inspect(other)}")
    end
  end

  defp record_bridge_requested(call_session, investor_call_id) do
    CallSession.handle_event(
      call_session,
      CallEvent.provider(:telnyx_webhook, :investor_bridge_requested, %{
        investor_call_control_id: investor_call_id
      })
    )
  end

  defp investor_outbound_context(%{"client_state" => client_state})
       when is_binary(client_state) do
    with {:ok, json} <- Base.decode64(client_state),
         {:ok, %{"kind" => "investor_outbound"} = decoded} <- Jason.decode(json),
         parent when is_binary(parent) <- decoded["parent_call_control_id"] do
      {:ok,
       %{
         parent_call_control_id: parent,
         investor_identity: decoded["investor_identity"] || %{}
       }}
    else
      _other -> :none
    end
  end

  defp investor_outbound_context(_payload), do: :none

  defp investor_client_state(context) do
    %{
      kind: :investor_outbound,
      parent_call_control_id: context.parent_call_control_id,
      investor_identity: context.investor_identity || %{}
    }
    |> Jason.encode!()
    |> Base.encode64()
  end
end
