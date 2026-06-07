defmodule Negotiator.CallSession.ProviderJobs do
  @moduledoc """
  runs provider work outside the call session process.
  """

  alias Negotiator.Agents.{NegotiationAgent, SimulatedInvestor, SmallTalkAgent}
  alias Negotiator.{Memory, Tools}
  alias Negotiator.SileroVad.Probabilistic
  alias Negotiator.LLM.Speech.Models, as: SpeechModels

  @doc """
  starts a queued continuation prediction job.
  """
  def queued_continuation(owner, state, source, prompt_text, checkpoint) do
    start(
      owner,
      state.call_id,
      :queued_continuation,
      service_metadata(state, source: source, checkpoint: checkpoint),
      fn ->
        continuation = SmallTalkAgent.queued_continuation(state, prompt_text)
        %{source: source, continuation: continuation, checkpoint: checkpoint}
      end
    )
  end

  @doc """
  starts a private negotiation advice job with sentence-level streaming.
  """
  def negotiation_advice(owner, state) do
    start(owner, state.call_id, :negotiation_advice, service_metadata(state), fn ->
      advice = NegotiationAgent.advise(state)
      voice = Tools.synthesize_voice(state.coach_voice, advice, coach_voice_opts())
      %{advice: advice, voice: voice}
    end)
  end

  @doc """
  starts the small-talk agent reply with sentence-level streaming.
  bypasses streaming when a pre-ranked candidate is available.
  """
  def small_talk_reply(owner, state) do
    start(owner, state.call_id, :small_talk_reply, service_metadata(state), fn ->
      reply = SmallTalkAgent.reply(state)
      selected_candidate = SmallTalkAgent.selected_candidate(state)

      stream_sentences_with_tts(
        owner,
        state.call_id,
        :small_talk_reply,
        reply,
        state.voice,
        founder_voice_opts()
      )

      %{reply: reply, selected_candidate: selected_candidate}
    end)
  end

  @doc """
  starts the simulated investor reply with sentence-level streaming.
  """
  def investor_reply(owner, state) do
    start(owner, state.call_id, :investor_reply, service_metadata(state), fn ->
      reply = SimulatedInvestor.next_turn(state)

      stream_sentences_with_tts(
        owner,
        state.call_id,
        :investor_reply,
        reply,
        state.investor_voice,
        investor_voice_opts(state.investor_voice)
      )

      %{reply: reply}
    end)
  end

  defp stream_sentences_with_tts(owner, _call_id, kind, text, voice_module, voice_opts) do
    sentences = split_into_sentences(text)

    sentences
    |> Enum.with_index()
    |> Task.async_stream(
      fn {sentence, index} ->
        voice = Tools.synthesize_voice(voice_module, sentence, voice_opts)
        {index, sentence, voice}
      end,
      max_concurrency: 2,
      ordered: true,
      timeout: 30_000
    )
    |> Enum.each(fn
      {:ok, {index, sentence_text, voice}} ->
        send(owner, {:provider_job_sentence, kind, index, sentence_text, voice})

      {:exit, _reason} ->
        :ok
    end)

    length(sentences)
  end

  defp split_into_sentences(text) do
    trimmed = String.trim(text || "")

    if trimmed == "" do
      []
    else
      trimmed
      |> String.split(~r/(?<=[.!?])\s+/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> case do
        [] -> [trimmed]
        sentences -> sentences
      end
    end
  end

  @doc """
  refreshes moss retrieval context in the background after a speech turn.
  results are deduplicated and cached in memory for agents to read.
  """
  def retrieval_refresh(owner, state) do
    call_id = state.call_id

    start(owner, call_id, :retrieval_refresh, service_metadata(state), fn ->
      query = Memory.recent_text(call_id, 6)

      case Memory.moss_search(call_id, query, limit: 6) do
        {:ok, results} ->
          Memory.write(call_id, %{retrieval_context: results})
          %{total: length(results), source: :moss_session}

        {:error, _reason} ->
          %{total: 0, source: :moss_session}
      end
    end)
  end

  @doc """
  runs background research on the founder's company.
  generates search queries from the conversation, fires parallel web searches,
  and progressively writes results to memory as they arrive.
  """
  def investor_research(owner, state) do
    call_id = state.call_id

    start(owner, call_id, :investor_research, service_metadata(state), fn ->
      queries = SimulatedInvestor.research_queries(state)

      results =
        queries
        |> Task.async_stream(
          fn query ->
            case Tools.research_search(state.research, query) do
              {:ok, search_results} ->
                Memory.append_to_list(call_id, :investor_research, search_results)
                search_results

              {:error, _reason} ->
                []
            end
          end,
          max_concurrency: 3,
          ordered: false,
          timeout: 15_000
        )
        |> Enum.flat_map(fn
          {:ok, r} -> r
          {:exit, _reason} -> []
        end)

      %{queries: queries, results: results}
    end)
  end

  @doc """
  starts model-backed turn detection after the heuristic decision is recorded.
  """
  def turn_detection(owner, state, input) do
    start(owner, state.call_id, :turn_detection, service_metadata(state), fn ->
      %{
        decision: state.turn_detection.score(input),
        role: Map.get(input, :role),
        text: Map.get(input, :text)
      }
    end)
  end

  def heuristic_turn_detection(input), do: Probabilistic.score(input)

  defp start(owner, call_id, kind, metadata, fun) do
    ref = make_ref()
    metadata = [ref: inspect(ref)] ++ metadata
    Negotiator.Logging.provider_job(:started, call_id, kind, metadata)

    case Memory.async(call_id, fn -> run(owner, call_id, ref, kind, metadata, fun) end) do
      {:ok, _pid} ->
        {:ok, ref}

      {:error, reason} ->
        Negotiator.Logging.provider_job(
          :failed,
          call_id,
          kind,
          Keyword.put(metadata, :reason, inspect(reason))
        )

        {:error, reason}
    end
  end

  defp run(owner, call_id, ref, kind, metadata, fun) do
    started_at = System.monotonic_time(:millisecond)

    result =
      try do
        {:ok, fun.()}
      rescue
        error -> {:error, error}
      catch
        caught_kind, reason -> {:error, {caught_kind, reason}}
      end

    duration_ms = System.monotonic_time(:millisecond) - started_at
    log_provider_result(call_id, kind, result, duration_ms, metadata)
    send(owner, {:provider_job_result, ref, kind, result})
  end

  defp log_provider_result(call_id, kind, {:ok, _result}, duration_ms, metadata) do
    Negotiator.Logging.provider_job(
      :finished,
      call_id,
      kind,
      Keyword.put(metadata, :duration_ms, duration_ms)
    )
  end

  defp log_provider_result(call_id, kind, {:error, reason}, duration_ms, metadata) do
    Negotiator.Logging.provider_job(
      :failed,
      call_id,
      kind,
      metadata
      |> Keyword.put(:duration_ms, duration_ms)
      |> Keyword.put(:reason, inspect(reason))
    )
  end

  defp service_metadata(state, extra \\ []) do
    [
      llm_service: module_label(state.llm),
      retrieval_service: module_label(state.retrieval),
      voice_service: module_label(state.voice),
      coach_voice_service: module_label(state.coach_voice),
      investor_voice_service: module_label(state.investor_voice),
      research_service: module_label(state.research),
      turn_detection_service: module_label(state.turn_detection)
    ] ++ extra
  end

  defp module_label(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp module_label(other), do: other

  defp founder_voice_opts do
    put_voice_id_if_present([role: :small_talk_agent], SpeechModels.elevenlabs_founder_voice_id())
  end

  defp coach_voice_opts do
    put_voice_id_if_present([role: :negotiation_agent], SpeechModels.elevenlabs_coach_voice_id())
  end

  defp investor_voice_opts(Negotiator.LLM.Speech.ElevenLabs) do
    put_voice_id_if_present([role: :investor], SpeechModels.elevenlabs_investor_voice_id())
  end

  defp investor_voice_opts(_module), do: [role: :investor]

  defp put_voice_id_if_present(opts, value) when is_binary(value) and value != "" do
    Keyword.put(opts, :voice_id, value)
  end

  defp put_voice_id_if_present(opts, _missing), do: opts
end
