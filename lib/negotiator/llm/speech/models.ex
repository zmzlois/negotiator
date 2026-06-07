defmodule Negotiator.LLM.Speech.Models do
  @moduledoc """
  central model and voice names for speech providers.
  """

  alias Negotiator.Env

  @elevenlabs_speech "eleven_flash_v2_5"
  @elevenlabs_output_format "ulaw_8000"

  @doc """
  returns the elevenlabs speech model for the founder voice clone.
  """
  def elevenlabs_speech, do: Env.get("ELEVENLABS_MODEL_ID", @elevenlabs_speech)

  @doc """
  returns the elevenlabs telephony output format.
  """
  def elevenlabs_output_format, do: Env.get("ELEVENLABS_OUTPUT_FORMAT", @elevenlabs_output_format)

  @doc """
  returns the elevenlabs investor voice id.
  """
  def elevenlabs_investor_voice_id, do: Env.get("ELEVENLABS_INVESTOR_VOICE_ID")

  @doc """
  returns the elevenlabs founder voice id for the small-talk cloned voice.
  """
  def elevenlabs_founder_voice_id do
    Env.get("FOUNDER_VOICE_ID") || Env.get("ELEVENLABS_VOICE_ID")
  end

  @doc """
  returns the elevenlabs coach voice id.
  """
  def elevenlabs_coach_voice_id do
    Env.get("ELEVENLABS_COACH_VOICE_ID") || Env.get("ELEVENLABS_VOICE_ID")
  end
end
