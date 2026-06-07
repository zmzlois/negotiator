defmodule Negotiator.CallSession.State do
  @moduledoc """
  data shape and boot defaults for one call session.
  """

  alias Negotiator.{
    Env,
    Dev,
    CallSession.TranscriptionQueue,
    InvestorIdentity,
    Orchestration,
    Providers,
    Research,
    ResponseLifecycle,
    Retrieval,
    Transcript,
    SileroVad
  }

  alias Negotiator.LLM.Speech

  defstruct call_id: nil,
            mode: :normal,
            sequence: 0,
            events: [],
            transcript: [],
            transcription_queue: TranscriptionQueue.new(),
            candidates: [],
            response_queue: [],
            response_lifecycle: ResponseLifecycle.initial(),
            active_response_refs: %{},
            active_playback_marks: %{},
            idle_timer_ref: nil,
            idle_timer_handle: nil,
            idle_prompt_count: 0,
            last_human_speech_at: nil,
            response_gate_ref: nil,
            response_gate_handle: nil,
            last_transcription_at: nil,
            last_vad_silence_at: nil,
            last_eot_decision: nil,
            prediction_checkpoint: 0,
            latest_turn_decision: nil,
            briefing: nil,
            orchestration: Orchestration.for_mode(:normal),
            media_socket_pid: nil,
            media_sockets: %{},
            phone_participant: :founder,
            latest_audio_participant: nil,
            audio_buffer: <<>>,
            latest_investor_partial: nil,
            latest_speech_partials: %{},
            investor_research: [],
            founder_phone: nil,
            investor_identity: %{name: nil, number: nil, firm: nil},
            pre_call_stage: :choosing,
            investor_bridge: %{status: :idle},
            transcription_commit_bytes: 8_000,
            llm: Negotiator.LLM.OpenAI,
            retrieval: Retrieval.Disabled,
            research: Research.Disabled,
            speech_to_text: Dev.SpeechToText,
            voice: Speech.ElevenLabs,
            coach_voice: Speech.ElevenLabs,
            investor_voice: Speech.ElevenLabs,
            turn_detection: SileroVad.Probabilistic

  @doc """
  creates a call session state using runtime provider defaults.
  """
  def new(opts) do
    %__MODULE__{
      call_id: Keyword.get(opts, :call_id, "call-#{System.unique_integer([:positive])}"),
      orchestration: Orchestration.for_mode(:normal),
      llm: Keyword.get(opts, :llm, Providers.llm()),
      retrieval: Keyword.get(opts, :retrieval, Providers.retrieval()),
      speech_to_text: Keyword.get(opts, :speech_to_text, Providers.speech_to_text()),
      transcription_commit_bytes: Keyword.get(opts, :transcription_commit_bytes, 8_000),
      investor_identity: InvestorIdentity.from_opts(opts),
      research: Keyword.get(opts, :research, Providers.research()),
      phone_participant: Keyword.get(opts, :phone_participant, configured_phone_participant()),
      voice: Keyword.get(opts, :voice, Providers.voice()),
      coach_voice: Keyword.get(opts, :coach_voice, Providers.coach_voice()),
      investor_voice: Keyword.get(opts, :investor_voice, Providers.investor_voice()),
      turn_detection: Keyword.get(opts, :turn_detection, Providers.turn_detection())
    }
  end

  @doc """
  returns the compact shared memory payload for other agents and processes.
  """
  def memory_snapshot(state) do
    %{
      mode: state.mode,
      sequence: state.sequence,
      events: state.events,
      transcript: state.transcript,
      transcription_queue: state.transcription_queue,
      candidates: state.candidates,
      response_queue: state.response_queue,
      response_lifecycle: state.response_lifecycle,
      active_response_refs: state.active_response_refs,
      active_playback_marks: state.active_playback_marks,
      idle_timer_active?: not is_nil(state.idle_timer_ref),
      idle_prompt_count: state.idle_prompt_count,
      prediction_checkpoint: state.prediction_checkpoint,
      latest_investor_partial: state.latest_investor_partial,
      latest_speech_partials: state.latest_speech_partials,
      investor_research: state.investor_research,
      founder_phone: state.founder_phone,
      investor_identity: state.investor_identity,
      pre_call_stage: state.pre_call_stage,
      investor_bridge: state.investor_bridge,
      phone_participant: state.phone_participant,
      latest_audio_participant: state.latest_audio_participant,
      media_socket_participants: Map.keys(state.media_sockets),
      briefing: state.briefing,
      orchestration: state.orchestration
    }
  end

  defp configured_phone_participant do
    "NEGOTIATOR_PHONE_PARTICIPANT"
    |> Env.get("founder")
    |> Transcript.normalize_role()
  end
end
