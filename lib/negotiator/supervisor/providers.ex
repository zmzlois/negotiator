defmodule Negotiator.Providers do
  @moduledoc """
  resolves runtime provider modules for live calls.
  """

  alias Negotiator.{Dev, LLM, Research, Retrieval, SileroVad}
  alias Negotiator.LLM.Speech

  def llm do
    Application.get_env(:negotiator, :llm, default_llm())
  end

  def speech_to_text do
    Application.get_env(:negotiator, :speech_to_text, default_speech_to_text())
  end

  def voice do
    Application.get_env(:negotiator, :voice, default_voice())
  end

  def coach_voice do
    Application.get_env(:negotiator, :coach_voice, default_coach_voice())
  end

  def investor_voice do
    Application.get_env(:negotiator, :investor_voice, default_investor_voice())
  end

  def retrieval do
    Application.get_env(:negotiator, :retrieval, default_retrieval())
  end

  def research do
    Application.get_env(:negotiator, :research, default_research())
  end

  def turn_detection do
    Application.get_env(:negotiator, :turn_detection, default_turn_detection())
  end

  defp default_llm do
    LLM.OpenAI
  end

  defp default_speech_to_text do
    Dev.SpeechToText
  end

  defp default_voice do
    case System.get_env("NEGOTIATOR_DEV_VOICE", "") do
      "local_pcmu" ->
        Dev.VoicePcmu

      _other ->
        Speech.ElevenLabs
    end
  end

  defp default_coach_voice do
    case System.get_env("NEGOTIATOR_DEV_COACH_VOICE", "") do
      "local_pcmu" -> Dev.VoicePcmu
      _other -> Speech.ElevenLabs
    end
  end

  defp default_investor_voice do
    case System.get_env("NEGOTIATOR_DEV_INVESTOR_VOICE", "") do
      "local_pcmu" -> Dev.VoicePcmu
      _other -> Speech.ElevenLabs
    end
  end

  defp default_retrieval do
    if present?("MOSS_PROJECT_ID") and present?("MOSS_INDEX_NAME") and
         (present?("MOSS_PROJECT_KEY") or present?("MOSS_API_KEY")) do
      Retrieval.Moss
    else
      Retrieval.Disabled
    end
  end

  defp default_turn_detection do
    if live_providers_required?() do
      SileroVad.Native
    else
      configured_turn_detection()
    end
  end

  defp configured_turn_detection do
    case System.get_env("NEGOTIATOR_TURN_DETECTION", "") |> String.downcase() do
      value when value in ["silero_vad", "silero", "vad"] ->
        SileroVad.Native

      value when value in ["llm", "openai"] ->
        SileroVad.LLM

      value when value in ["probabilistic", "local"] ->
        SileroVad.Probabilistic

      _default ->
        if silero_available?() do
          SileroVad.Native
        else
          SileroVad.Probabilistic
        end
    end
  end

  defp default_research do
    if present?("WEB_SEARCH_API_KEY") do
      Research.WebSearch
    else
      Research.Disabled
    end
  end

  defp present?(name), do: match?({:ok, value} when value != "", System.fetch_env(name))

  defp silero_available?, do: SileroVad.Native.available?()

  defp live_providers_required? do
    System.get_env("NEGOTIATOR_REQUIRE_LIVE_PROVIDERS", "0") in [
      "1",
      "true",
      "TRUE",
      "yes",
      "YES"
    ]
  end
end
