defmodule Negotiator.RuntimeStatus do
  @moduledoc """
  describes the live voice-ai runtime wiring without calling providers.
  """

  alias Negotiator.{
    AgentProfiles,
    Dev,
    Env,
    LLM,
    Providers,
    Research,
    Retrieval,
    SileroVad
  }

  alias Negotiator.LLM.Speech
  alias Negotiator.LLM.Models, as: LLMModels
  alias Negotiator.LLM.Speech.Models, as: SpeechModels

  require Logger

  @doc """
  returns the current app runtime shape without exposing secret values.
  """
  def snapshot do
    status = %{
      app: :negotiator,
      http: http_status(),
      telephony: telephony_status(),
      llm: llm_status(),
      voice: voice_status(),
      retrieval: retrieval_status(),
      extraction: extraction_status(),
      research: research_status(),
      speech_to_text: speech_to_text_status(),
      turn_detection: turn_detection_status(),
      agents: AgentProfiles.all()
    }

    Map.put(status, :live_voice, live_voice_status(status))
  end

  @doc """
  logs the selected runtime providers at startup.
  """
  def log_startup(snapshot \\ snapshot()) do
    live_voice = Map.fetch!(snapshot, :live_voice)

    Logger.info("voice runtime providers selected",
      live_voice_ready?: live_voice.ready?,
      llm: snapshot.llm.provider,
      public_voice: snapshot.voice.public_agent.provider,
      private_coach_voice: snapshot.voice.private_coach.provider,
      investor_voice: snapshot.voice.simulated_investor.provider,
      retrieval: snapshot.retrieval.provider,
      turn_detection: snapshot.turn_detection.provider,
      missing_live_requirements: Enum.map(live_voice.blockers, & &1.name)
    )

    :ok
  end

  @doc """
  raises when live provider mode is required but not ready.
  """
  def enforce_live_voice_ready!(snapshot \\ snapshot()) do
    live_voice = Map.fetch!(snapshot, :live_voice)

    if require_live_providers?() and not live_voice.ready? do
      blockers =
        live_voice.blockers
        |> Enum.map_join(", ", fn blocker ->
          missing =
            blocker
            |> Map.get(:missing, [])
            |> Enum.reject(&is_nil/1)
            |> Enum.join("|")

          if missing == "" do
            to_string(blocker.name)
          else
            "#{blocker.name}[#{missing}]"
          end
        end)

      raise """
      live voice providers are required but not ready: #{blockers}

      unset NEGOTIATOR_REQUIRE_LIVE_PROVIDERS for local development, or configure the missing provider env vars.
      """
    end

    :ok
  end

  @doc """
  returns true when live provider mode is required.
  """
  def require_live_providers? do
    Env.get("NEGOTIATOR_REQUIRE_LIVE_PROVIDERS", "0") in enabled_values()
  end

  defp http_status do
    %{
      enabled?: Env.get("NEGOTIATOR_HTTP_ENABLED", "0") == "1",
      port: Env.port(),
      health_path: "/health",
      runtime_path: "/runtime",
      call_inspection_paths: ["/calls", "/calls/:call_control_id"],
      dev_controls: %{
        enabled?: Env.get("NEGOTIATOR_DEV_CONTROLS_ENABLED", "0") in enabled_values(),
        paths: [
          "/dev/calls/:call_control_id/say",
          "/dev/calls/:call_control_id/partial",
          "/dev/calls/:call_control_id/transcription",
          "/dev/calls/:call_control_id/media-frame",
          "/dev/calls/:call_control_id/dtmf",
          "/dev/calls/:call_control_id/resume",
          "/dev/calls/:call_control_id/media/:participant/connect",
          "/dev/calls/:call_control_id/media/:participant",
          "/dev/telnyx/webhook"
        ]
      }
    }
  end

  defp telephony_status do
    %{
      provider: :telnyx,
      module: module_name(Negotiator.Telephony.Telnyx),
      ready?: env_ready?(:telnyx),
      env: env_summary(:telnyx),
      webhook_paths: ["/telnyx/webhook", "/webhooks/telnyx"],
      media_paths: ["/media/:call_control_id/:participant", "/telnyx/media-streaming"],
      media_streaming: %{
        track: Env.get("TELNYX_STREAM_TRACK", "both_tracks"),
        codec: Env.get("TELNYX_STREAM_CODEC", "PCMU"),
        bidirectional_mode: Env.get("TELNYX_STREAM_BIDIRECTIONAL_MODE", "rtp"),
        bidirectional_codec: Env.get("TELNYX_STREAM_BIDIRECTIONAL_CODEC", "PCMU"),
        bidirectional_target_legs: Env.get("TELNYX_STREAM_BIDIRECTIONAL_TARGET_LEGS", "self"),
        bidirectional_sampling_rate: Env.get("TELNYX_STREAM_BIDIRECTIONAL_SAMPLING_RATE", "8000")
      },
      transcription: %{
        enabled?: Env.get("TELNYX_TRANSCRIPTION_ENABLED", "1") in enabled_values(),
        tracks: Env.get("TELNYX_TRANSCRIPTION_TRACKS", "inbound"),
        role:
          Env.get("TELNYX_TRANSCRIPTION_ROLE", Env.get("NEGOTIATOR_PHONE_PARTICIPANT", "founder")),
        engine: Env.get("TELNYX_TRANSCRIPTION_ENGINE", "Telnyx"),
        model: Env.get("TELNYX_TRANSCRIPTION_MODEL"),
        interim_results?:
          Env.get("TELNYX_TRANSCRIPTION_INTERIM_RESULTS", "true") in enabled_values()
      }
    }
  end

  defp llm_status do
    module = Providers.llm()

    %{
      provider: provider_name(module, %{LLM.OpenAI => :openai}),
      module: module_name(module),
      live?: module == LLM.OpenAI,
      ready?: module == LLM.OpenAI and env_ready?(:openai_llm),
      env: env_summary(:openai_llm),
      model: LLMModels.openai_chat(),
      base_url_configured?: Env.present?("OPENAI_BASE_URL")
    }
  end

  defp voice_status do
    public_module = Providers.voice()
    private_module = Providers.coach_voice()
    investor_module = Providers.investor_voice()

    %{
      public_agent: %{
        role: :small_talk_agent,
        provider:
          provider_name(public_module, %{
            Speech.ElevenLabs => :elevenlabs,
            Dev.VoicePcmu => :dev_pcmu
          }),
        module: module_name(public_module),
        live?: public_module == Speech.ElevenLabs,
        ready?: public_module == Dev.VoicePcmu or env_ready?(:elevenlabs_voice),
        env: env_summary(:elevenlabs_voice),
        model: SpeechModels.elevenlabs_speech(),
        output_format: public_voice_output_format(public_module)
      },
      private_coach: %{
        role: :negotiation_agent,
        provider:
          provider_name(private_module, %{
            Speech.ElevenLabs => :elevenlabs,
            Dev.VoicePcmu => :dev_pcmu
          }),
        module: module_name(private_module),
        live?: private_module == Speech.ElevenLabs and Env.present?("ELEVENLABS_API_KEY"),
        ready?:
          private_module == Dev.VoicePcmu or env_ready?(:elevenlabs_voice),
        env: env_summary(:elevenlabs_voice),
        model: SpeechModels.elevenlabs_speech(),
        output_format: SpeechModels.elevenlabs_output_format(),
        voice_id_configured?: Env.present?("ELEVENLABS_VOICE_ID")
      },
      simulated_investor: %{
        role: :investor,
        provider:
          provider_name(investor_module, %{
            Speech.ElevenLabs => :elevenlabs,
            Dev.VoicePcmu => :dev_pcmu
          }),
        module: module_name(investor_module),
        live?:
          investor_module == Speech.ElevenLabs and Env.present?("ELEVENLABS_API_KEY"),
        ready?: investor_voice_ready?(investor_module),
        model: investor_voice_model(investor_module),
        output_format: investor_voice_output_format(investor_module),
        voice_id_configured?: Env.present?("ELEVENLABS_INVESTOR_VOICE_ID")
      }
    }
  end

  defp retrieval_status do
    module = Providers.retrieval()

    %{
      provider:
        provider_name(module, %{Retrieval.Moss => :moss, Retrieval.Disabled => :disabled}),
      module: module_name(module),
      live?: module == Retrieval.Moss,
      ready?: module == Retrieval.Disabled or env_ready?(:moss),
      env: env_summary(:moss),
      index_configured?: Env.present?("MOSS_INDEX_NAME")
    }
  end

  defp extraction_status do
    %{
      investor_identity: %{
        provider: :openai,
        module: module_name(LLM.OpenAI),
        live?: Env.present?("OPENAI_API_KEY"),
        ready?: env_ready?(:openai_identity),
        env: env_summary(:openai_identity),
        model: LLMModels.openai_identity()
      }
    }
  end

  defp research_status do
    module = Providers.research()

    %{
      provider:
        provider_name(module, %{Research.WebSearch => :web_search, Research.Disabled => :disabled}),
      module: module_name(module),
      live?: module == Research.WebSearch,
      ready?: module == Research.Disabled or Env.present?("WEB_SEARCH_API_KEY"),
      env: env_summary(:web_search)
    }
  end

  defp speech_to_text_status do
    module = Providers.speech_to_text()

    %{
      provider: provider_name(module, %{Dev.SpeechToText => :dev_fixture}),
      module: module_name(module),
      live_source: :telnyx_in_call_transcription,
      note: "speech text enters through telnyx webhook transcription events"
    }
  end

  defp live_voice_status(snapshot) do
    requirements = live_voice_requirements(snapshot)

    %{
      required?: require_live_providers?(),
      ready?: Enum.all?(requirements, & &1.ready?),
      requirements: requirements,
      blockers: Enum.reject(requirements, & &1.ready?)
    }
  end

  defp live_voice_requirements(snapshot) do
    [
      requirement(
        :telnyx_call_control,
        snapshot.telephony.ready?,
        snapshot.telephony.env.missing
      ),
      requirement(
        :openai_llm,
        snapshot.llm.provider == :openai and snapshot.llm.ready?,
        snapshot.llm.env.missing
      ),
      requirement(
        :elevenlabs_founder_clone,
        snapshot.voice.public_agent.provider == :elevenlabs and
          snapshot.voice.public_agent.ready?,
        snapshot.voice.public_agent.env.missing
      ),
      requirement(
        :elevenlabs_coach_voice,
        snapshot.voice.private_coach.provider == :elevenlabs and
          snapshot.voice.private_coach.ready?,
        snapshot.voice.private_coach.env.missing
      ),
      requirement(
        :moss_retrieval,
        snapshot.retrieval.provider == :moss and snapshot.retrieval.ready?,
        snapshot.retrieval.env.missing
      ),
      requirement(
        :openai_investor_identity,
        snapshot.extraction.investor_identity.ready?,
        snapshot.extraction.investor_identity.env.missing
      ),
      requirement(
        :endpointing,
        endpointing_ready?(snapshot.turn_detection),
        endpointing_missing(snapshot.turn_detection)
      )
    ]
  end

  defp requirement(name, ready?, missing) do
    %{
      name: name,
      ready?: !!ready?,
      missing: List.wrap(missing)
    }
  end

  defp endpointing_ready?(turn_detection) do
    if require_live_providers?() do
      turn_detection.provider == :silero_vad and turn_detection.silero.binary_available?
    else
      turn_detection.provider in [:silero_vad, :probabilistic, :llm] and
        (turn_detection.provider != :silero_vad or turn_detection.silero.binary_available?)
    end
  end

  defp endpointing_missing(%{provider: provider}) when provider != :silero_vad do
    if require_live_providers?(), do: ["NEGOTIATOR_TURN_DETECTION=silero_vad"], else: []
  end

  defp endpointing_missing(%{provider: :silero_vad, silero: %{binary_available?: false}}) do
    ["SILERO_VAD_BIN"]
  end

  defp endpointing_missing(_turn_detection), do: []

  defp turn_detection_status do
    module = Providers.turn_detection()

    %{
      provider:
        provider_name(module, %{
          SileroVad.Native => :silero_vad,
          SileroVad.Probabilistic => :probabilistic,
          SileroVad.LLM => :llm
        }),
      module: module_name(module),
      local_audio_endpointing?: module == SileroVad.Native,
      probabilistic_fallback?: module == SileroVad.Probabilistic,
      env: env_summary(:turn_detection),
      silero: %{
        binary_path: SileroVad.Native.bin_path(),
        binary_available?: SileroVad.Native.available?(),
        model_path: Env.get("SILERO_VAD_MODEL", "priv/models/silero_vad.onnx"),
        model_configured?: Env.present?("SILERO_VAD_MODEL")
      },
      partial_checkpoint_words: 3
    }
  end

  defp env_summary(provider) do
    required = Env.required(provider)
    optional = Env.optional(provider)

    %{
      required: required,
      missing: Enum.reject(required, &Env.present?/1),
      present_required: Enum.filter(required, &Env.present?/1),
      optional_present: Enum.filter(optional, &Env.present?/1)
    }
  end

  defp env_ready?(provider), do: env_summary(provider).missing == []

  defp provider_name(module, names), do: Map.get(names, module, :custom)

  defp module_name(module), do: inspect(module)

  defp enabled_values, do: [true, "1", "true", "TRUE", "yes", "YES"]

  defp public_voice_output_format(Dev.VoicePcmu), do: "ulaw_8000"
  defp public_voice_output_format(_module), do: SpeechModels.elevenlabs_output_format()


  defp investor_voice_ready?(Dev.VoicePcmu), do: true
  defp investor_voice_ready?(Speech.ElevenLabs), do: env_ready?(:elevenlabs_voice)
  defp investor_voice_ready?(_module), do: false

  defp investor_voice_model(Speech.ElevenLabs),
    do: SpeechModels.elevenlabs_speech()

  defp investor_voice_model(_module), do: nil

  defp investor_voice_output_format(Dev.VoicePcmu), do: "ulaw_8000"

  defp investor_voice_output_format(Speech.ElevenLabs) do
    SpeechModels.elevenlabs_output_format()
  end

  defp investor_voice_output_format(_module), do: "pcmu_8000"

end
