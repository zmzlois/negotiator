defmodule Negotiator.AgentProfiles do
  @moduledoc """
  documents the live provider split for each ai role.
  """

  @profiles %{
    small_talk: %{
      role: :small_talk_agent,
      audience: :investor,
      room: :small_talk,
      line_task: :small_talk_reply,
      llm_provider: :openai_chat,
      voice_provider: :elevenlabs_clone,
      retrieval_provider: :moss,
      turn_detection: [:silero_vad, :probabilistic]
    },
    negotiator: %{
      role: :negotiation_agent,
      audience: :founder,
      room: :briefing,
      line_task: :negotiation_advice,
      llm_provider: :openai_chat,
      voice_provider: :elevenlabs,
      retrieval_provider: :moss,
      turn_detection: [:silero_vad, :probabilistic]
    }
  }

  @doc """
  returns all configured ai role profiles.
  """
  def all, do: @profiles

  @doc """
  returns a single ai role profile.
  """
  def fetch!(name), do: Map.fetch!(@profiles, name)
end
