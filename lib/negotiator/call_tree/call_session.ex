defmodule Negotiator.CallSession do
  @moduledoc """
  owns one negotiation call state machine.
  """

  use GenServer

  @idle_timeout_ms 10_000
  @max_idle_prompts 2
  @drop_timeout_ms 30_000

  alias Negotiator.CallSession.{
    Audio,
    EventLog,
    Modes,
    ProviderJobs,
    ResponseGate,
    ResponseTracking,
    Snapshot,
    Speech,
    State,
    Transcription,
    TranscriptionQueue
  }

  alias Negotiator.{
    CallEvent,
    InvestorIdentity,
    Memory,
    Orchestration,
    Prediction,
    PredictionCoordinator,
    Prompts,
    ResponseLifecycle,
    ResponseQueue,
    Telephony.Telnyx,
    Tools,
    Transcript,
    SileroVad
  }

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def state(call_session) do
    GenServer.call(call_session, :state)
  end

  def say(call_session, role, text) do
    GenServer.call(call_session, {:say, role, text})
  end

  def partial(call_session, role, text, opts \\ []) do
    GenServer.call(call_session, {:partial, role, text, opts})
  end

  def handle_event(call_session, %CallEvent{} = event) do
    GenServer.call(call_session, {:call_event, event})
  end

  def press_digit(call_session, digit) do
    handle_event(call_session, CallEvent.dtmf(digit))
  end

  def resume_founder(call_session) do
    GenServer.call(call_session, :resume_founder)
  end

  def telephony_event(call_session, type, payload \\ %{}) do
    handle_event(call_session, CallEvent.provider(:telephony, type, payload))
  end

  def register_media_socket(call_session, socket_pid, opts \\ []) when is_pid(socket_pid) do
    handle_event(call_session, CallEvent.register_media_socket(socket_pid, Map.new(opts)))
  end

  def media_frame(call_session, bytes, metadata \\ %{}) when is_binary(bytes) do
    handle_event(call_session, CallEvent.media_frame(bytes, metadata))
  end

  def end_call(call_session, reason \\ :normal) do
    handle_event(call_session, CallEvent.end_call(reason))
  end

  @impl true
  def init(opts) do
    state = State.new(opts)

    sync(state)

    {:ok, append_event(state, :call_started, %{call_id: state.call_id})}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, snapshot(state), state}
  end

  def handle_call({:call_event, %CallEvent{} = event}, _from, state) do
    {reply, state} = apply_call_event(state, event)
    {:reply, reply, state}
  end

  def handle_call({:say, role, text}, _from, state) do
    role = normalize_role(role)

    state =
      state
      |> interrupt_audio_on_participant_speech(role, :participant_speech_started)
      |> queue_final_transcription(role, text, %{source: :manual_say})
      |> record_speech(role, text)
      |> apply_pre_call_intent(role, text)
      |> refresh_predictions(role)
      |> enqueue_room_agents_after_investor_turn(role)
      |> enqueue_simulated_investor_after_founder_turn(role)

    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call({:partial, role, text, opts}, _from, state) do
    role = normalize_role(role)
    state = record_partial_speech(state, role, text, Map.new(opts))

    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call(:resume_founder, _from, state) do
    state =
      state
      |> Modes.return_founder(:api)
      |> clear_phone_audio(:founder_returning)
      |> sync()

    {:reply, {:ok, snapshot(state)}, state}
  end

  @impl true
  def handle_info({:provider_job_result, ref, kind, result}, state) do
    {:noreply, apply_provider_job_result(state, ref, kind, result)}
  end

  def handle_info({:idle_timeout, ref, awaited_role, turn_count}, state) do
    {:noreply, apply_idle_timeout(state, ref, awaited_role, turn_count)}
  end

  def handle_info({:gated_response_fire, ref, role, text}, state) do
    {:noreply, apply_gated_response(state, ref, role, text)}
  end

  def handle_info({:provider_job_sentence, kind, index, sentence_text, voice_result}, state) do
    {:noreply, apply_sentence_result(state, kind, index, sentence_text, voice_result)}
  end

  def handle_info({:identity_extracted, incoming, founder_text}, state) do
    identity = InvestorIdentity.merge(state.investor_identity, incoming)

    state =
      state
      |> Map.put(:investor_identity, identity)
      |> append_event(:investor_identity_updated, %{
        source: :founder_speech,
        missing_fields: InvestorIdentity.missing_fields(identity),
        investor_identity: InvestorIdentity.metadata(identity)
      })
      |> start_investor_identity_collection_on_intent(founder_text)
      |> dial_investor_when_identity_complete()

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_idle_timer(state)
    cancel_response_gate(state)
    Memory.drop(state.call_id, state.founder_phone)
    :ok
  end

  defp apply_call_event(state, %CallEvent{source: source, type: type, payload: payload})
       when source in [:telephony, :telnyx_webhook, :media_socket] and
              type not in [
                :dtmf,
                :register,
                :media_frame,
                :media_mark,
                :transcription,
                :end_call
              ] do
    state =
      state
      |> capture_founder_phone(type, payload)
      |> unregister_closed_media_socket(type, payload)
      |> apply_investor_identity_event(type, payload)
      |> apply_investor_bridge_event(type, payload)
      |> append_event(type, payload)

    {{:ok, snapshot(state)}, state}
  end

  defp apply_call_event(state, %CallEvent{
         source: :media_socket,
         type: :media_mark,
         payload: payload
       }) do
    name = Map.get(payload, :name) || Map.get(payload, "name")
    active_mark = state.response_lifecycle.playback_mark

    state =
      case ResponseTracking.take_playback_mark(state, name) do
        {:ok, state, metadata} ->
          state
          |> advance_response_after_mark(name, active_mark, metadata)
          |> append_event(:media_mark_received, Map.merge(payload, %{playback: metadata}))

        :stale ->
          append_event(state, :media_mark_ignored, Map.put(payload, :active_mark, active_mark))
      end

    {{:ok, snapshot(state)}, state}
  end

  defp apply_call_event(state, %CallEvent{
         type: :register,
         payload: %{socket_pid: socket_pid} = payload
       }) do
    participant =
      payload
      |> Map.get(:participant, state.phone_participant)
      |> normalize_role()

    state =
      state
      |> Map.put(:media_socket_pid, socket_pid)
      |> Map.update!(:media_sockets, &Map.put(&1, participant, socket_pid))
      |> set_primary_phone_participant_if_first_socket(participant)
      |> append_event(:media_socket_registered, %{
        pid: inspect(socket_pid),
        participant: participant
      })
      |> start_opening_prompt_for_founder(participant)

    {{:ok, snapshot(state)}, state}
  end

  defp apply_call_event(state, %CallEvent{
         type: :transcription,
         payload: %{text: text, final?: false} = payload
       }) do
    metadata = Map.delete(payload, :text)
    role = transcription_role(payload)
    state = record_partial_speech(state, role, text, metadata)
    {{:ok, snapshot(state)}, state}
  end

  defp apply_call_event(state, %CallEvent{
         type: :transcription,
         payload: %{text: text, final?: true} = payload
       }) do
    role = transcription_role(payload)

    state =
      state
      |> append_event(:speech_transcribed, %{
        provider: :telnyx_in_call,
        role: role,
        text: String.trim(text),
        confidence: payload[:confidence],
        metadata: Map.delete(payload, :text)
      })
      |> Map.put(:latest_investor_partial, nil)
      |> clear_latest_partial(role)
      |> record_transcribed_turn_if_new(role, text, Map.delete(payload, :text))

    {{:ok, snapshot(state)}, state}
  end

  defp apply_call_event(state, %CallEvent{
         type: :media_frame,
         payload: %{bytes: bytes, metadata: metadata}
       }) do
    metadata = normalize_media_metadata(metadata, state)

    payload =
      metadata
      |> Map.new()
      |> Map.put(:bytes, byte_size(bytes))

    state =
      state
      |> Map.put(:latest_audio_participant, Map.fetch!(metadata, :participant))
      |> Map.update!(:audio_buffer, &(&1 <> bytes))
      |> append_event(:media_frame_received, payload)
      |> transcribe_media_audio_if_needed(metadata)

    {{:ok, snapshot(state)}, state}
  end

  defp apply_call_event(state, %CallEvent{type: :end_call, payload: %{reason: reason}}) do
    state =
      state
      |> cancel_idle_timer()
      |> transcribe_audio_if_ready(%{force_transcribe?: true})
      |> Modes.change(:ended)
      |> append_event(:call_ended, %{reason: reason})

    {{:ok, snapshot(state)}, state}
  end

  defp apply_call_event(state, %CallEvent{type: :dtmf, payload: %{digit: "3"}}) do
    state =
      state
      |> append_event(:dtmf_received, %{digit: "3"})
      |> Modes.change(:briefing)
      |> sync()
      |> append_event(:founder_muted, %{reason: :briefing_started})
      |> add_negotiation_advice()
      |> enqueue_small_talk_after_latest_investor_turn()

    {{:ok, snapshot(state)}, state}
  end

  defp apply_call_event(state, %CallEvent{type: :dtmf, payload: %{digit: "4"}}) do
    state =
      state
      |> append_event(:dtmf_received, %{digit: "4"})
      |> Modes.change(:agent_takeover)
      |> sync()
      |> append_event(:founder_side_listening, %{small_talk_agent: :active})
      |> enqueue_small_talk_reply()

    {{:ok, snapshot(state)}, state}
  end

  defp apply_call_event(state, %CallEvent{type: :dtmf, payload: %{digit: "5"}}) do
    state =
      state
      |> append_event(:dtmf_received, %{digit: "5"})
      |> Modes.return_founder(:dtmf)
      |> clear_phone_audio(:founder_returning)
      |> sync()

    {{:ok, snapshot(state)}, state}
  end

  defp apply_call_event(state, %CallEvent{type: :dtmf, payload: %{digit: "9"}}) do
    state =
      state
      |> append_event(:dtmf_received, %{digit: "9"})
      |> Modes.change(:practice)
      |> sync()
      |> append_event(:practice_mode_activated, %{})
      |> enqueue_investor_reply()

    {{:ok, snapshot(state)}, state}
  end

  defp apply_call_event(state, %CallEvent{type: :dtmf, payload: %{digit: digit}}) do
    state = append_event(state, :dtmf_ignored, %{digit: digit})
    {{:ignored, snapshot(state)}, state}
  end

  defp apply_call_event(state, %CallEvent{} = event) do
    state =
      append_event(state, :call_event_ignored, %{
        source: event.source,
        type: event.type,
        payload: event.payload
      })

    {{:ignored, snapshot(state)}, state}
  end

  defp apply_investor_identity_event(state, type, payload)
       when type in [:telnyx_call_initiated, :telnyx_call_answered, :investor_call_answered] do
    incoming = InvestorIdentity.from_payload(payload)

    if InvestorIdentity.empty?(incoming) do
      state
    else
      Map.update!(state, :investor_identity, &InvestorIdentity.merge(&1, incoming))
    end
  end

  defp apply_investor_identity_event(state, _type, _payload), do: state

  defp capture_founder_phone(%{founder_phone: nil} = state, :telnyx_call_initiated, payload) do
    case payload do
      %{"from" => "+" <> _ = phone} ->
        state
        |> Map.put(:founder_phone, phone)
        |> load_founder_knowledge(phone)

      _ ->
        state
    end
  end

  defp capture_founder_phone(state, _type, _payload), do: state

  defp load_founder_knowledge(state, phone) do
    Memory.async(state.call_id, fn ->
      Memory.MossSession.load_founder_index(state.call_id, phone)
    end)

    state
  end

  defp extract_investor_identity_from_founder_speech(state, :founder, text) do
    call_session = self()
    transcript_text = identity_extraction_text(state, text)

    Memory.async(state.call_id, fn ->
      incoming = InvestorIdentity.from_transcript(transcript_text)

      unless InvestorIdentity.empty?(incoming) do
        send(call_session, {:identity_extracted, incoming, text})
      end
    end)

    state
  end

  defp extract_investor_identity_from_founder_speech(state, _role, _text), do: state

  defp identity_extraction_text(state, text) do
    Prompts.investor_identity_transcript(state.transcript, text)
  end

  defp apply_pre_call_intent(%{pre_call_stage: :choosing} = state, :founder, text) do
    cond do
      pitch_practice_intent?(text) ->
        state
        |> Map.put(:pre_call_stage, :pitch_practice)
        |> Modes.change(:practice)
        |> append_event(:pitch_practice_started, %{source: :founder_speech})

      investor_call_intent?(text) ->
        start_investor_identity_collection_on_intent(state, text)

      true ->
        state
    end
  end

  defp apply_pre_call_intent(state, _role, _text), do: state

  defp start_investor_identity_collection_on_intent(%{pre_call_stage: stage} = state, text)
       when stage in [:choosing, :idle] do
    if investor_call_intent?(text) do
      state
      |> Map.put(:pre_call_stage, :collecting_investor)
      |> append_event(:investor_identity_collection_started, %{
        missing_fields: InvestorIdentity.missing_fields(state.investor_identity)
      })
    else
      state
    end
  end

  defp start_investor_identity_collection_on_intent(state, _text), do: state

  defp dial_investor_when_identity_complete(%{pre_call_stage: :pitch_practice} = state), do: state

  defp dial_investor_when_identity_complete(state) do
    identity = InvestorIdentity.normalize(state.investor_identity)
    bridge_status = Map.get(state.investor_bridge, :status, :idle)

    cond do
      bridge_status in [:dialing, :answered, :bridging, :bridged] ->
        state

      not InvestorIdentity.complete?(identity) ->
        append_event(state, :investor_identity_incomplete, %{
          missing_fields: InvestorIdentity.missing_fields(identity),
          investor_identity: InvestorIdentity.metadata(identity)
        })

      true ->
        dial_investor(state, identity)
    end
  end

  defp dial_investor(state, identity) do
    case Tools.dial_investor(configured_telephony(), state.call_id, identity) do
      {:ok, response} ->
        outbound_call_control_id = outbound_call_control_id(response)

        state
        |> Map.put(:pre_call_stage, :dialing_investor)
        |> Map.put(:investor_bridge, %{
          status: :dialing,
          parent_call_control_id: state.call_id,
          investor_call_control_id: outbound_call_control_id,
          investor_identity: InvestorIdentity.metadata(identity)
        })
        |> append_event(:investor_dial_requested, %{
          investor_call_control_id: outbound_call_control_id,
          investor_identity: InvestorIdentity.metadata(identity)
        })

      :ok ->
        state
        |> Map.put(:pre_call_stage, :dialing_investor)
        |> Map.put(:investor_bridge, %{
          status: :dialing,
          parent_call_control_id: state.call_id,
          investor_identity: InvestorIdentity.metadata(identity)
        })
        |> append_event(:investor_dial_requested, %{
          investor_identity: InvestorIdentity.metadata(identity)
        })

      {:error, reason} ->
        state
        |> Map.put(:investor_bridge, %{
          status: :dial_failed,
          reason: inspect(reason),
          investor_identity: InvestorIdentity.metadata(identity)
        })
        |> append_event(:investor_dial_failed, %{
          reason: inspect(reason),
          investor_identity: InvestorIdentity.metadata(identity)
        })
    end
  end

  defp apply_investor_bridge_event(state, :investor_dial_initiated, payload) do
    update_investor_bridge(state, :dialing, payload)
  end

  defp apply_investor_bridge_event(state, :investor_call_answered, payload) do
    update_investor_bridge(state, :answered, payload)
  end

  defp apply_investor_bridge_event(state, :investor_bridge_requested, payload) do
    update_investor_bridge(state, :bridging, payload)
  end

  defp apply_investor_bridge_event(state, :investor_bridged, payload) do
    state
    |> Map.put(:pre_call_stage, :investor_bridged)
    |> update_investor_bridge(:bridged, payload)
  end

  defp apply_investor_bridge_event(state, :investor_call_hangup, payload) do
    update_investor_bridge(state, :investor_hangup, payload)
  end

  defp apply_investor_bridge_event(state, _type, _payload), do: state

  defp update_investor_bridge(state, status, payload) do
    investor_call_control_id =
      Map.get(payload, :investor_call_control_id) || Map.get(payload, "investor_call_control_id") ||
        Map.get(payload, "call_control_id")

    bridge =
      state.investor_bridge
      |> Map.put(:status, status)
      |> put_bridge_if_present(:investor_call_control_id, investor_call_control_id)
      |> put_bridge_if_present(:updated_at, DateTime.utc_now())

    Map.put(state, :investor_bridge, bridge)
  end

  defp put_bridge_if_present(map, _key, value) when value in [nil, ""], do: map
  defp put_bridge_if_present(map, key, value), do: Map.put(map, key, value)

  defp outbound_call_control_id(%{data: %{"call_control_id" => call_control_id}}),
    do: call_control_id

  defp outbound_call_control_id(%{"data" => %{"call_control_id" => call_control_id}}),
    do: call_control_id

  defp outbound_call_control_id(%{body: body}), do: outbound_call_control_id(body)
  defp outbound_call_control_id(_response), do: nil

  defp configured_telephony do
    Application.get_env(:negotiator, :telnyx_client, Telnyx)
  end

  defp pitch_practice_intent?(text) do
    text = String.downcase(text || "")
    String.contains?(text, "pitch practice") or String.contains?(text, "practice my pitch")
  end

  defp investor_call_intent?(text) do
    text = String.downcase(text || "")

    Enum.any?(["call", "dial", "phone", "investor"], &String.contains?(text, &1))
  end

  defp apply_provider_job_result(state, _ref, :queued_continuation, {:ok, result}) do
    checkpoint = Map.get(result, :checkpoint)

    if stale_continuation_result?(state, checkpoint) do
      append_event(state, :queued_continuation_result_ignored, %{
        source: Map.get(result, :source),
        checkpoint: checkpoint,
        current_checkpoint: state.prediction_checkpoint
      })
    else
      apply_queued_continuation_result(state, result)
    end
  end

  defp apply_provider_job_result(state, _ref, :queued_continuation, {:error, reason}) do
    append_event(state, :queued_continuation_failed, %{reason: inspect(reason)})
  end

  @max_investor_research 100

  defp apply_provider_job_result(state, _ref, :investor_research, {:ok, result}) do
    results = Map.get(result, :results, [])

    state
    |> Map.update!(:investor_research, &Enum.take(&1 ++ results, @max_investor_research))
    |> sync()
    |> append_event(:investor_research_completed, %{
      queries: Map.get(result, :queries, []),
      result_count: length(results)
    })
  end

  defp apply_provider_job_result(state, _ref, :investor_research, {:error, reason}) do
    append_event(state, :investor_research_failed, %{reason: inspect(reason)})
  end

  defp apply_provider_job_result(state, _ref, :retrieval_refresh, {:ok, result}) do
    append_event(state, :retrieval_context_refreshed, %{
      total: Map.get(result, :total, 0),
      new: Map.get(result, :new, 0)
    })
  end

  defp apply_provider_job_result(state, _ref, :retrieval_refresh, {:error, reason}) do
    append_event(state, :retrieval_refresh_failed, %{reason: inspect(reason)})
  end

  defp apply_provider_job_result(
         state,
         _ref,
         :turn_detection,
         {:ok, %{decision: decision, role: role, text: text}}
       ) do
    role = normalize_role(role)
    text = String.trim(text || "")

    state
    |> Map.put(:latest_turn_decision, decision)
    |> append_event(:turn_detection_updated, %{
      role: role,
      text: text,
      end_probability: decision.end_probability,
      should_reply: decision.should_reply?,
      reason: decision.reason
    })
    |> commit_model_partial_turn_if_eot(role, text, decision)
  end

  defp apply_provider_job_result(state, _ref, :turn_detection, {:ok, decision}) do
    state
    |> Map.put(:latest_turn_decision, decision)
    |> append_event(:turn_detection_updated, %{
      end_probability: decision.end_probability,
      should_reply: decision.should_reply?,
      reason: decision.reason
    })
  end

  defp apply_provider_job_result(state, _ref, :turn_detection, {:error, reason}) do
    append_event(state, :turn_detection_failed, %{reason: inspect(reason)})
  end

  defp apply_provider_job_result(state, ref, kind, result)
       when kind in [:negotiation_advice, :small_talk_reply, :investor_reply] do
    case ResponseTracking.take_job(state, ref, kind) do
      {:ok, state} ->
        apply_active_response_job_result(state, ref, kind, result)

      :stale ->
        append_event(state, :response_job_result_ignored, %{
          kind: kind,
          ref: inspect(ref),
          reason: :stale_or_interrupted
        })
    end
  end

  defp apply_provider_job_result(state, _ref, kind, {:ok, result}) do
    append_event(state, :provider_job_ignored, %{kind: kind, result: inspect(result)})
  end

  defp apply_provider_job_result(state, _ref, kind, {:error, reason}) do
    append_event(state, :provider_job_failed, %{kind: kind, reason: inspect(reason)})
  end

  defp apply_active_response_job_result(
         state,
         _ref,
         :negotiation_advice,
         {:ok, %{advice: advice} = result}
       ) do
    state
    |> Map.put(:briefing, advice)
    |> sync()
    |> record_speech(:negotiation_agent, advice, source: :llm)
    |> append_event(:negotiation_advice_created, %{text: advice})
    |> record_negotiation_voice_result(result[:voice])
  end

  defp apply_active_response_job_result(state, _ref, :negotiation_advice, {:ok, advice}) do
    state
    |> Map.put(:briefing, advice)
    |> sync()
    |> record_speech(:negotiation_agent, advice, source: :llm)
    |> append_event(:negotiation_advice_created, %{text: advice})
  end

  defp apply_active_response_job_result(state, _ref, :negotiation_advice, {:error, reason}) do
    append_event(state, :negotiation_advice_failed, %{reason: inspect(reason)})
  end

  defp apply_active_response_job_result(state, _ref, :small_talk_reply, {:ok, result})
       when state.mode in [:briefing, :agent_takeover] do
    reply = Map.fetch!(result, :reply)
    room = Orchestration.room_for_role(state.orchestration, :small_talk_agent)
    selected_candidate = Map.get(result, :selected_candidate)

    state
    |> record_speech(:small_talk_agent, reply, source: :llm)
    |> remove_spoken_candidate(selected_candidate)
    |> append_event(:small_talk_agent_spoke, %{
      text: reply,
      room: room,
      voice: :elevenlabs_clone,
      selected_candidate: selected_candidate,
      remaining_candidates:
        ResponseQueue.texts(ResponseQueue.remove(state.response_queue, selected_candidate))
    })
  end

  defp apply_active_response_job_result(state, _ref, :small_talk_reply, {:ok, _result}) do
    state
    |> transition_response(:muted, %{reason: :wrong_mode})
    |> append_event(:small_talk_agent_result_ignored, %{mode: state.mode})
  end

  defp apply_active_response_job_result(state, _ref, :small_talk_reply, {:error, reason}) do
    state
    |> transition_response(:failed, %{reason: inspect(reason), role: :small_talk_agent})
    |> append_event(:small_talk_agent_failed, %{reason: inspect(reason)})
  end

  defp apply_active_response_job_result(state, _ref, :investor_reply, {:ok, result}) do
    reply = Map.fetch!(result, :reply)

    state
    |> record_speech(:investor, reply, source: :llm)
    |> enqueue_room_agents_after_investor_turn(:investor)
    |> append_event(:investor_spoke, %{text: reply, voice: :investor})
  end

  defp apply_active_response_job_result(state, _ref, :investor_reply, {:error, reason}) do
    state
    |> transition_response(:failed, %{reason: inspect(reason), role: :investor})
    |> append_event(:investor_reply_failed, %{reason: inspect(reason)})
  end

  defp record_negotiation_voice_result(%{briefing: advice} = state, {:ok, output}) do
    record_voice_output(state, :negotiation_agent, output, advice)
  end

  defp record_negotiation_voice_result(state, {:error, reason}) do
    append_event(state, :negotiation_voice_failed, %{reason: inspect(reason)})
  end

  defp record_negotiation_voice_result(state, _missing), do: state

  defp apply_queued_continuation_result(state, result) do
    queue =
      ResponseQueue.enqueue(state.response_queue, Map.fetch!(result, :continuation), %{
        source: result[:source],
        checkpoint: result[:checkpoint]
      })

    state
    |> Map.put(:response_queue, queue)
    |> Map.put(:candidates, ResponseQueue.texts(queue))
    |> sync()
    |> append_event(:queued_continuation_updated, %{
      source: Map.get(result, :source),
      checkpoint: Map.get(result, :checkpoint),
      queued: ResponseQueue.texts(queue),
      next: ResponseQueue.best(queue)
    })
  end

  defp remove_spoken_candidate(state, nil), do: state

  defp remove_spoken_candidate(state, candidate) do
    queue = ResponseQueue.remove(state.response_queue, candidate)

    state
    |> Map.put(:response_queue, queue)
    |> Map.put(:candidates, ResponseQueue.texts(queue))
    |> sync()
  end

  defp stale_continuation_result?(_state, nil), do: false
  defp stale_continuation_result?(state, checkpoint), do: checkpoint < state.prediction_checkpoint

  defp record_speech(state, role, text, opts \\ []) do
    state
    |> cancel_idle_timer_on_human_speech(role)
    |> track_human_speech_at(role)
    |> extract_investor_identity_from_founder_speech(role, text)
    |> Speech.record(role, text, opts)
    |> sync()
  end

  defp track_human_speech_at(state, role) when role in [:founder, :investor] do
    Map.put(state, :last_human_speech_at, System.monotonic_time(:millisecond))
  end

  defp track_human_speech_at(state, _role), do: state

  defp total_silence_ms(%{last_human_speech_at: nil}), do: 0

  defp total_silence_ms(%{last_human_speech_at: ts}) do
    System.monotonic_time(:millisecond) - ts
  end

  defp refresh_predictions(state, :investor) do
    case PredictionCoordinator.refresh_final_if_needed(state) do
      {:refresh, next_state, job} ->
        enqueue_queued_continuation(next_state, job)

      {:unchanged, next_state, _candidates} ->
        next_state
    end
  end

  defp refresh_predictions(state, _role), do: state

  defp refresh_predictions_from_partial(state, :investor, text) do
    case PredictionCoordinator.refresh_partial_if_needed(state, text) do
      {:refresh, next_state, job} ->
        enqueue_queued_continuation(next_state, job)

      {:unchanged, next_state, _candidates} ->
        next_state
    end
  end

  defp refresh_predictions_from_partial(state, _role, _text), do: state

  defp track_latest_transcription(state, role, text, metadata)
       when role in [:founder, :investor] do
    queue = TranscriptionQueue.set_latest(state.transcription_queue, role, text, metadata)

    state
    |> Map.put(:transcription_queue, queue)
    |> sync()
  end

  defp track_latest_transcription(state, _role, _text, _metadata), do: state

  defp queue_final_transcription(state, role, text, metadata)
       when role in [:founder, :investor] do
    queue = TranscriptionQueue.queue_final(state.transcription_queue, role, text, metadata)

    state
    |> Map.put(:transcription_queue, queue)
    |> sync()
  end

  defp queue_final_transcription(state, _role, _text, _metadata), do: state

  defp record_partial_speech(state, role, text, metadata) do
    text = String.trim(text || "")
    silence_ms = Map.get(metadata, :silence_ms, 0)

    turn_input = %{
      call_id: state.call_id,
      role: role,
      text: text,
      llm: state.llm,
      transcript: state.transcript,
      candidates: state.candidates,
      silence_ms: silence_ms,
      stable_words: Prediction.word_count(text)
    }

    turn_decision = ProviderJobs.heuristic_turn_detection(turn_input)

    state
    |> cancel_idle_timer_on_human_speech(role)
    |> cancel_response_gate_on_speech(role)
    |> interrupt_audio_on_participant_speech(role, :participant_speech_started)
    |> track_latest_transcription(role, text, metadata)
    |> store_speech_partial(role, text)
    |> Map.put(:latest_turn_decision, turn_decision)
    |> Map.put(:last_transcription_at, System.monotonic_time(:millisecond))
    |> Map.put(:last_eot_decision, turn_decision)
    |> append_event(:speech_partial, %{
      role: role,
      text: text,
      silence_ms: silence_ms,
      end_probability: turn_decision.end_probability,
      should_reply: turn_decision.should_reply?,
      source: Map.get(metadata, :source, :call_session),
      confidence: Map.get(metadata, :confidence)
    })
    |> start_model_turn_detection_job(turn_input)
    |> refresh_predictions_from_partial(role, text)
    |> commit_probabilistic_partial_turn_if_eot(role, text, turn_decision)
  end

  defp store_speech_partial(state, role, text)
       when role in [:founder, :investor] and is_binary(text) and text != "" do
    state =
      Map.update!(state, :latest_speech_partials, fn partials ->
        Map.put(partials, role, String.trim(text))
      end)

    if role == :investor do
      Map.put(state, :latest_investor_partial, String.trim(text))
    else
      state
    end
  end

  defp store_speech_partial(state, _role, _text), do: state

  defp enqueue_room_agents_after_investor_turn(state, :investor)
       when state.mode in [:briefing, :agent_takeover] do
    state
    |> enqueue_negotiation_advice()
    |> enqueue_small_talk_reply()
  end

  defp enqueue_room_agents_after_investor_turn(state, _role), do: state

  defp enqueue_simulated_investor_after_founder_turn(state, :founder)
       when state.mode == :practice do
    state
    |> enqueue_investor_reply()
    |> enqueue_investor_research_if_enough_context()
  end

  defp enqueue_simulated_investor_after_founder_turn(%{pre_call_stage: :collecting_investor} = state, :founder) do
    enqueue_investor_reply(state)
  end

  defp enqueue_simulated_investor_after_founder_turn(%{pre_call_stage: stage} = state, :founder)
       when stage in [:dialing_investor, :investor_bridged] do
    state
  end

  defp enqueue_simulated_investor_after_founder_turn(state, :founder)
       when state.mode == :normal do
    enqueue_investor_reply(state)
  end

  defp enqueue_simulated_investor_after_founder_turn(state, _role), do: state

  defp transcribe_media_audio_if_needed(%{turn_detection: SileroVad.Native} = state, metadata) do
    if Map.get(metadata, :force_transcribe?, false) or Map.get(metadata, :commit?, false) do
      transcribe_audio_if_ready(state, metadata)
    else
      state
    end
  end

  defp transcribe_media_audio_if_needed(state, metadata),
    do: transcribe_audio_if_ready(state, metadata)

  defp transcribe_audio_if_ready(state, metadata) do
    role = audio_speaker_role(state, metadata)

    case Transcription.commit_if_ready(state, metadata) do
      {:transcribed, state, text} -> record_transcribed_turn_if_new(state, role, text, metadata)
      {_result, state} -> state
      {_result, state, _reason} -> sync(state)
    end
  end

  defp record_transcribed_turn_if_new(state, role, text, metadata \\ %{})
  defp record_transcribed_turn_if_new(state, _role, "", _metadata), do: state

  defp record_transcribed_turn_if_new(state, role, text, metadata) do
    text = String.trim(text || "")

    if role not in [:founder, :investor] and latest_role_text(state, role) == text do
      append_event(state, :speech_final_duplicate_ignored, %{role: role, text: text})
    else
      state
      |> interrupt_audio_on_participant_speech(role, :participant_speech_started)
      |> queue_final_transcription(role, text, metadata)
      |> record_speech(role, text)
      |> apply_pre_call_intent(role, text)
      |> refresh_predictions(role)
      |> enqueue_replies_after_transcribed_turn(role)
      |> maybe_enqueue_retrieval_refresh()
    end
  end

  defp latest_role_text(state, role) do
    state.transcript
    |> Enum.reverse()
    |> Enum.find_value("", fn turn ->
      if turn.role == role, do: turn.text
    end)
  end

  defp latest_partial_text(state, role) do
    Map.get(state.latest_speech_partials, role, "")
  end

  defp clear_latest_partial(state, role) do
    state =
      Map.update!(state, :latest_speech_partials, fn partials ->
        Map.delete(partials, role)
      end)

    if role == :investor do
      Map.put(state, :latest_investor_partial, nil)
    else
      state
    end
  end

  defp enqueue_replies_after_transcribed_turn(state, :investor) do
    enqueue_room_agents_after_investor_turn(state, :investor)
  end

  defp enqueue_replies_after_transcribed_turn(state, :founder) do
    state
    |> enqueue_simulated_investor_after_founder_turn(:founder)
    |> enqueue_briefing_reply_to_founder()
  end

  defp enqueue_replies_after_transcribed_turn(state, _role), do: state

  defp enqueue_briefing_reply_to_founder(%{mode: :briefing} = state) do
    enqueue_negotiation_advice(state)
  end

  defp enqueue_briefing_reply_to_founder(state), do: state

  defp add_negotiation_advice(state) do
    enqueue_negotiation_advice(state)
  end

  defp enqueue_small_talk_after_latest_investor_turn(state) do
    if latest_transcript_role(state) == :investor do
      enqueue_small_talk_reply(state)
    else
      append_event(state, :small_talk_agent_waiting, %{reason: :waiting_for_investor_turn})
    end
  end

  defp enqueue_queued_continuation(state, %{
         source: source,
         prompt_text: prompt_text,
         checkpoint: checkpoint
       }) do
    case ProviderJobs.queued_continuation(self(), state, source, prompt_text, checkpoint) do
      {:ok, ref} ->
        append_event(state, :queued_continuation_job_started, %{
          ref: inspect(ref),
          source: source,
          checkpoint: checkpoint
        })

      {:error, reason} ->
        append_event(state, :queued_continuation_failed, %{
          reason: inspect(reason),
          source: source,
          checkpoint: checkpoint
        })
    end
  end

  defp enqueue_negotiation_advice(state) do
    case ProviderJobs.negotiation_advice(self(), state) do
      {:ok, ref} ->
        state
        |> ResponseTracking.track_job(ref, :negotiation_advice, :negotiation_agent)
        |> append_event(:negotiation_advice_job_started, %{ref: inspect(ref)})

      {:error, reason} ->
        append_event(state, :negotiation_advice_failed, %{reason: inspect(reason)})
    end
  end

  defp enqueue_investor_reply(%{pre_call_stage: stage} = state)
       when stage in [:dialing_investor, :investor_bridged] do
    append_event(state, :investor_reply_skipped, %{reason: :pre_call_stage, stage: stage})
  end

  defp enqueue_investor_reply(state) do
    if response_job_active?(state, :investor_reply) do
      append_event(state, :investor_reply_skipped, %{reason: :already_active})
    else
      case ProviderJobs.investor_reply(self(), state) do
        {:ok, ref} ->
          state
          |> ResponseTracking.track_job(ref, :investor_reply, :investor)
          |> transition_response(:synthesizing, %{
            response_id: inspect(ref),
            role: :investor,
            route: audio_route(state)
          })
          |> append_event(:investor_reply_job_started, %{ref: inspect(ref)})

        {:error, reason} ->
          append_event(state, :investor_reply_failed, %{reason: inspect(reason)})
      end
    end
  end

  defp start_opening_prompt_for_founder(%{mode: :normal, transcript: []} = state, :founder) do
    if response_job_active?(state, :investor_reply) do
      append_event(state, :opening_prompt_skipped, %{reason: :investor_reply_active})
    else
      state
      |> append_event(:opening_prompt_started, %{role: :investor})
      |> enqueue_investor_reply()
    end
  end

  defp start_opening_prompt_for_founder(state, _participant), do: state

  defp response_job_active?(state, kind) do
    Enum.any?(state.active_response_refs, fn
      {_ref, %{kind: ^kind}} -> true
      _other -> false
    end)
  end

  defp enqueue_investor_research_if_enough_context(state) do
    latest_founder =
      state.transcript
      |> Enum.reverse()
      |> Enum.find_value("", fn turn ->
        if turn.role == :founder, do: turn.text
      end)

    word_count = latest_founder |> String.split() |> length()

    if word_count >= 5 do
      case ProviderJobs.investor_research(self(), state) do
        {:ok, ref} ->
          append_event(state, :investor_research_job_started, %{ref: inspect(ref)})

        {:error, reason} ->
          append_event(state, :investor_research_failed, %{reason: inspect(reason)})
      end
    else
      state
    end
  end

  defp maybe_enqueue_retrieval_refresh(state) do
    case ProviderJobs.retrieval_refresh(self(), state) do
      {:ok, _ref} -> state
      {:error, _reason} -> state
    end
  end

  defp enqueue_small_talk_reply(state) do
    if small_talk_response_active?(state) do
      append_event(state, :small_talk_agent_queue_skipped, %{reason: :already_active})
    else
      start_small_talk_reply(state)
    end
  end

  defp start_small_talk_reply(state) do
    case ProviderJobs.small_talk_reply(self(), state) do
      {:ok, ref} ->
        state
        |> ResponseTracking.track_job(ref, :small_talk_reply, :small_talk_agent)
        |> transition_response(:synthesizing, %{
          response_id: inspect(ref),
          role: :small_talk_agent,
          route: audio_route(state)
        })
        |> append_event(:small_talk_agent_job_started, %{ref: inspect(ref)})

      {:error, reason} ->
        append_event(state, :small_talk_agent_failed, %{reason: inspect(reason)})
    end
  end

  defp small_talk_response_active?(%{
         response_lifecycle: %{role: :small_talk_agent, status: status}
       })
       when status in [:synthesizing, :speaking],
       do: true

  defp small_talk_response_active?(_state), do: false

  defp start_model_turn_detection_job(state, input) do
    if state.turn_detection in [SileroVad.Probabilistic, SileroVad.Native] do
      state
    else
      case ProviderJobs.turn_detection(self(), state, input) do
        {:ok, ref} ->
          append_event(state, :turn_detection_job_started, %{ref: inspect(ref)})

        {:error, reason} ->
          append_event(state, :turn_detection_failed, %{reason: inspect(reason)})
      end
    end
  end

  defp commit_probabilistic_partial_turn_if_eot(
         %{turn_detection: SileroVad.Probabilistic} = state,
         role,
         text,
         %{should_reply?: true} = decision
       )
       when role in [:founder, :investor] do
    state
    |> append_event(:probabilistic_turn_committed, %{
      role: role,
      text: text,
      end_probability: decision.end_probability,
      reason: decision.reason
    })
    |> schedule_gated_response(role, text)
  end

  defp commit_probabilistic_partial_turn_if_eot(state, _role, _text, _decision), do: state

  defp commit_model_partial_turn_if_eot(
         state,
         role,
         text,
         %{should_reply?: true} = decision
       )
       when role in [:founder, :investor] do
    text = String.trim(text || "")
    latest_text = latest_partial_text(state, role)

    cond do
      text == "" ->
        append_event(state, :turn_detection_result_ignored, %{
          role: role,
          reason: :empty_partial
        })

      latest_text != text ->
        append_event(state, :turn_detection_result_ignored, %{
          role: role,
          text: text,
          latest_text: latest_text,
          reason: :stale_partial
        })

      true ->
        state
        |> append_event(:model_turn_committed, %{
          role: role,
          text: text,
          end_probability: decision.end_probability,
          reason: decision.reason
        })
        |> clear_latest_partial(role)
        |> schedule_gated_response(role, text)
    end
  end

  defp commit_model_partial_turn_if_eot(state, _role, _text, _decision), do: state

  defp interrupt_audio_on_participant_speech(state, role, reason)
       when role in [:founder, :investor] do
    cond do
      active_phone_audio?(state) ->
        clear_phone_audio(state, reason)

      response_work_active?(state) ->
        interrupt_response_work(state, reason)

      true ->
        state
    end
  end

  defp interrupt_audio_on_participant_speech(state, _role, _reason), do: state

  defp active_phone_audio?(%{response_lifecycle: %{status: :speaking}}),
    do: true

  defp active_phone_audio?(_state), do: false

  defp response_work_active?(state), do: map_size(state.active_response_refs) > 0

  defp advance_response_after_mark(state, mark_name, _active_mark, playback)
       when map_size(state.active_playback_marks) == 0 do
    state
    |> finish_transcription_playing(mark_name)
    |> transition_response(:done, %{
      reason: :media_mark,
      playback_mark: mark_name,
      sent_to_media_socket?: true
    })
    |> schedule_idle_prompt_after_audio(playback)
  end

  defp advance_response_after_mark(state, mark_name, active_mark, _playback)
       when active_mark == mark_name or is_nil(active_mark) do
    {next_mark, next_playback} = Enum.at(state.active_playback_marks, 0)

    transition_response(state, :speaking, %{
      role: next_playback.role,
      route: audio_route(state),
      provider: next_playback.provider,
      playback_mark: next_mark,
      sent_to_media_socket?: true
    })
  end

  defp advance_response_after_mark(state, _mark_name, _active_mark, _playback), do: state

  defp apply_sentence_result(state, kind, index, sentence_text, voice_result) do
    role = sentence_role(kind)

    case voice_result do
      {:ok, output} ->
        state
        |> record_voice_output(role, output, sentence_text)
        |> append_event(:sentence_audio_ready, %{
          kind: kind,
          index: index,
          text: sentence_text
        })

      {:error, reason} ->
        append_event(state, :sentence_audio_failed, %{
          kind: kind,
          index: index,
          text: sentence_text,
          reason: inspect(reason)
        })
    end
  end

  defp sentence_role(:investor_reply), do: :investor
  defp sentence_role(:small_talk_reply), do: :small_talk_agent
  defp sentence_role(:negotiation_advice), do: :negotiation_agent
  defp sentence_role(_kind), do: :small_talk_agent

  defp record_voice_output(state, role, output, spoken_text) do
    {sent_to_media_socket?, playback_mark, mute_reason} =
      Audio.send_voice_output(state, output, role)

    state
    |> advance_transcription_after_voice_output(
      sent_to_media_socket?,
      role,
      spoken_text,
      playback_mark
    )
    |> ResponseTracking.track_playback_mark(playback_mark, role, output)
    |> transition_after_voice_output(
      role,
      output,
      sent_to_media_socket?,
      playback_mark,
      mute_reason
    )
    |> append_event(:voice_audio_ready, %{
      provider: output.provider,
      format: output.format,
      bytes: byte_size(output.bytes || ""),
      metadata: output.metadata,
      sent_to_media_socket?: sent_to_media_socket?,
      playback_mark: playback_mark,
      reason: mute_reason
    })
  end

  defp transition_after_voice_output(
         state,
         role,
         output,
         true,
         playback_mark,
         mute_reason
       ) do
    transition_response(state, :speaking, %{
      role: role,
      route: audio_route(state),
      provider: output.provider,
      sent_to_media_socket?: true,
      playback_mark: primary_playback_mark(playback_mark),
      reason: mute_reason
    })
  end

  defp transition_after_voice_output(state, role, output, false, playback_mark, mute_reason) do
    transition_response(state, :muted, %{
      role: role,
      route: audio_route(state),
      provider: output.provider,
      sent_to_media_socket?: false,
      playback_mark: primary_playback_mark(playback_mark),
      reason: mute_reason
    })
  end

  defp primary_playback_mark([mark_name | _rest]), do: mark_name
  defp primary_playback_mark(mark_name), do: mark_name

  defp advance_transcription_after_voice_output(state, true, role, text, playback_mark) do
    mark_transcription_playing(state, role, text, playback_mark)
  end

  defp advance_transcription_after_voice_output(state, false, _role, _text, _playback_mark) do
    Map.update!(state, :transcription_queue, &TranscriptionQueue.clear_response_state/1)
  end

  defp mark_transcription_playing(state, role, text, playback_mark) do
    {queue, _playing} =
      TranscriptionQueue.start_playing(
        state.transcription_queue,
        role,
        text,
        primary_playback_mark(playback_mark)
      )

    Map.put(state, :transcription_queue, queue)
  end

  defp finish_transcription_playing(state, playback_mark) do
    queue =
      state.transcription_queue
      |> TranscriptionQueue.finish_playing(playback_mark)
      |> TranscriptionQueue.clear_playing()

    Map.put(state, :transcription_queue, queue)
  end

  defp clear_phone_audio(state, reason) do
    cleared? = Audio.clear_output(state, reason)

    state
    |> Map.put(:active_response_refs, %{})
    |> Map.put(:active_playback_marks, %{})
    |> Map.update!(:transcription_queue, &TranscriptionQueue.clear_response_state/1)
    |> transition_response(:interrupted, %{
      reason: reason,
      sent_to_media_socket?: cleared?
    })
    |> append_event(:phone_audio_clear_requested, %{
      reason: reason,
      sent_to_media_socket?: cleared?
    })
  end

  defp interrupt_response_work(state, reason) do
    state
    |> Map.put(:active_response_refs, %{})
    |> Map.update!(:transcription_queue, &TranscriptionQueue.clear_response_state/1)
    |> transition_response(:interrupted, %{
      reason: reason,
      sent_to_media_socket?: false
    })
    |> append_event(:response_work_interrupted, %{
      reason: reason,
      sent_to_media_socket?: false
    })
  end

  defp schedule_idle_prompt_after_audio(state, %{role: role})
       when role in [:investor, :small_talk_agent] do
    eligible? =
      case role do
        :investor -> state.mode in [:normal, :practice]
        :small_talk_agent -> state.mode in [:briefing, :agent_takeover]
      end

    cond do
      not eligible? -> state
      state.idle_prompt_count >= @max_idle_prompts -> state
      active_phone_audio?(state) -> state
      true -> schedule_idle_prompt(state)
    end
  end

  defp schedule_idle_prompt_after_audio(state, _playback), do: state

  defp schedule_idle_prompt(state) do
    state = cancel_idle_timer(state)
    awaited_role = idle_awaited_role(state.mode)
    turn_count = transcript_role_count(state, awaited_role)
    message_ref = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:idle_timeout, message_ref, awaited_role, turn_count},
        @idle_timeout_ms
      )

    state
    |> Map.put(:idle_timer_ref, message_ref)
    |> Map.put(:idle_timer_handle, timer_ref)
    |> append_event(:idle_timer_started, %{
      awaited_role: awaited_role,
      turn_count: turn_count,
      timeout_ms: @idle_timeout_ms,
      mode: state.mode
    })
  end

  defp apply_idle_timeout(%{idle_timer_ref: ref} = state, ref, awaited_role, turn_count) do
    state =
      state
      |> Map.put(:idle_timer_ref, nil)
      |> Map.put(:idle_timer_handle, nil)

    cond do
      state.mode == :ended ->
        state

      active_phone_audio?(state) ->
        state

      transcript_role_count(state, awaited_role) != turn_count ->
        append_event(state, :idle_timer_cancelled, %{reason: :human_spoke, role: awaited_role})

      total_silence_ms(state) >= @drop_timeout_ms ->
        state
        |> append_event(:drop_timeout_reached, %{
          silence_ms: total_silence_ms(state),
          drop_timeout_ms: @drop_timeout_ms
        })
        |> Modes.change(:ended)
        |> append_event(:call_ended, %{reason: :silence_timeout})

      state.idle_prompt_count >= @max_idle_prompts ->
        state

      true ->
        state
        |> Map.update!(:idle_prompt_count, &(&1 + 1))
        |> append_event(:idle_prompt_started, %{
          awaited_role: awaited_role,
          turn_count: turn_count
        })
        |> enqueue_idle_reply()
    end
  end

  defp apply_idle_timeout(state, _ref, _awaited_role, _turn_count), do: state

  defp cancel_idle_timer(%{idle_timer_ref: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer_handle: timer_ref} = state) do
    if is_reference(timer_ref), do: Process.cancel_timer(timer_ref)

    state
    |> Map.put(:idle_timer_ref, nil)
    |> Map.put(:idle_timer_handle, nil)
  end

  defp idle_awaited_role(mode) when mode in [:briefing, :agent_takeover], do: :investor
  defp idle_awaited_role(_mode), do: :founder

  defp enqueue_idle_reply(state) when state.mode in [:briefing, :agent_takeover],
    do: enqueue_small_talk_reply(state)

  defp enqueue_idle_reply(state),
    do: enqueue_investor_reply(state)

  defp cancel_idle_timer_on_human_speech(state, :founder)
       when state.mode in [:normal, :practice],
       do: cancel_idle_timer(state)

  defp cancel_idle_timer_on_human_speech(state, :investor)
       when state.mode in [:briefing, :agent_takeover],
       do: cancel_idle_timer(state)

  defp cancel_idle_timer_on_human_speech(state, _role), do: state

  # -- response gate: delays response dispatch to avoid cutting users off --

  defp schedule_gated_response(state, role, text) do
    state = cancel_response_gate(state)
    delay = ResponseGate.delay_ms(state)
    ref = make_ref()

    if delay <= 0 do
      record_transcribed_turn_if_new(state, role, text)
    else
      handle = Process.send_after(self(), {:gated_response_fire, ref, role, text}, delay)

      state
      |> Map.put(:response_gate_ref, ref)
      |> Map.put(:response_gate_handle, handle)
      |> append_event(:response_gated, %{role: role, delay_ms: delay})
    end
  end

  defp apply_gated_response(%{response_gate_ref: expected_ref} = state, ref, role, text)
       when ref == expected_ref do
    state
    |> Map.put(:response_gate_ref, nil)
    |> Map.put(:response_gate_handle, nil)
    |> append_event(:response_gate_fired, %{role: role})
    |> record_transcribed_turn_if_new(role, text)
  end

  defp apply_gated_response(state, _ref, _role, _text), do: state

  defp cancel_response_gate(%{response_gate_ref: nil} = state), do: state

  defp cancel_response_gate(state) do
    if state.response_gate_handle, do: Process.cancel_timer(state.response_gate_handle)

    state
    |> Map.put(:response_gate_ref, nil)
    |> Map.put(:response_gate_handle, nil)
  end

  defp cancel_response_gate_on_speech(state, role) when role in [:founder, :investor] do
    cancel_response_gate(state)
  end

  defp cancel_response_gate_on_speech(state, _role), do: state

  defp transcript_role_count(state, role) do
    Enum.count(state.transcript, &(&1.role == role))
  end


  defp sync(state) do
    Memory.write(state.call_id, State.memory_snapshot(state))
    state
  end

  defp unregister_closed_media_socket(state, :media_socket_closed, payload) do
    participant = Map.get(payload, :participant) || Map.get(payload, "participant")

    case normalize_optional_role(participant) do
      nil ->
        state

      participant ->
        Map.update!(state, :media_sockets, &Map.delete(&1, participant))
    end
  end

  defp unregister_closed_media_socket(state, _type, _payload), do: state

  defp set_primary_phone_participant_if_first_socket(
         %{media_sockets: sockets} = state,
         participant
       ) do
    if map_size(sockets) == 1 do
      Map.put(state, :phone_participant, participant)
    else
      state
    end
  end

  defp transition_response(state, status, metadata) do
    state =
      Map.put(
        state,
        :response_lifecycle,
        ResponseLifecycle.transition(state.response_lifecycle, status, metadata)
      )

    sync(state)
  end

  defp audio_route(state), do: Audio.route(state)

  defp latest_transcript_role(%{transcript: []}), do: nil

  defp latest_transcript_role(state) do
    state.transcript
    |> List.last()
    |> Map.get(:role)
  end


  @sync_events MapSet.new([
    :call_started,
    :call_ended,
    :mode_changed,
    :practice_mode_activated,
    :investor_spoke,
    :small_talk_agent_spoke,
    :negotiation_advice_created,
    :investor_research_completed,
    :retrieval_context_refreshed,
    :response_gate_fired,
    :idle_prompt_started,
    :drop_timeout_reached
  ])

  defp append_event(state, type, payload) do
    state = EventLog.append(state, type, payload)
    if MapSet.member?(@sync_events, type), do: sync(state), else: state
  end

  defp snapshot(state) do
    Snapshot.build(state)
  end

  defp normalize_role(role), do: Transcript.normalize_role(role)

  defp normalize_optional_role(nil), do: nil
  defp normalize_optional_role(role), do: normalize_role(role)

  defp transcription_role(payload) do
    payload
    |> Map.get(:role, :founder)
    |> normalize_role()
  end

  defp normalize_media_metadata(metadata, state) do
    metadata = Map.new(metadata)

    participant =
      metadata
      |> Map.get(:participant, Map.get(metadata, "participant", state.phone_participant))
      |> normalize_role()

    Map.put(metadata, :participant, participant)
  end

  defp audio_speaker_role(state, metadata) do
    metadata = Map.new(metadata)

    metadata
    |> Map.get(:participant, state.latest_audio_participant || state.phone_participant)
    |> normalize_role()
  end
end
