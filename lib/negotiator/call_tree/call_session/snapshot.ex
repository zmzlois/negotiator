defmodule Negotiator.CallSession.Snapshot do
  @moduledoc """
  builds read-only call session snapshots.
  """

  alias Negotiator.CallSession.Audio

  def build(state) do
    %{
      call_id: state.call_id,
      mode: state.mode,
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
      latest_turn_decision: state.latest_turn_decision,
      latest_investor_partial: state.latest_investor_partial,
      founder_phone: state.founder_phone,
      investor_identity: state.investor_identity,
      pre_call_stage: state.pre_call_stage,
      investor_bridge: state.investor_bridge,
      briefing: state.briefing,
      orchestration: state.orchestration,
      audio_route: Audio.route(state),
      phone_participant: state.phone_participant,
      latest_audio_participant: state.latest_audio_participant,
      latest_speech_partials: state.latest_speech_partials,
      media_socket_participants: Map.keys(state.media_sockets),
      providers: %{
        llm: state.llm,
        retrieval: state.retrieval,
        speech_to_text: state.speech_to_text,
        voice: state.voice,
        coach_voice: state.coach_voice,
        investor_voice: state.investor_voice,
        turn_detection: state.turn_detection
      },
      runtime: Negotiator.RuntimeStatus.snapshot(),
      audio_buffer_bytes: byte_size(state.audio_buffer),
      events: state.events,
      last_events: Enum.take(state.events, -8)
    }
  end
end
