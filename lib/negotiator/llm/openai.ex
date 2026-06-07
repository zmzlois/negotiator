defmodule Negotiator.LLM.OpenAI do
  @moduledoc """
  openai chat and structured response adapter.
  """

  @behaviour Negotiator.LLM

  alias Negotiator.{Env, InvestorIdentity, Logging, Prompts, Tools}
  alias Negotiator.LLM.{Models, ToolDefs, ToolExecutor}

  require Logger

  @base_url "https://api.openai.com/v1"
  @max_tool_rounds 1

  # --- llm behaviour: chat completions ---

  @impl true
  def complete(task, input) do
    config = resolve_chat_provider()
    messages = messages(task, input)
    tools = ToolDefs.for_task(task)
    tool_context = tool_context(input)

    log_started(config, task, input, messages)

    complete_with_tools(config, task, messages, tools, tool_context, 0)
  end

  defp complete_with_tools(config, task, messages, tools, tool_context, round) do
    %{api_key: api_key, model: model, base_url: base_url, provider: provider} = config
    started_at = System.monotonic_time(:millisecond)

    body =
      %{model: model, messages: messages, temperature: temperature(task), stream: false}
      |> maybe_add_tools(tools)

    case Tools.http_post(chat_completions_url(base_url),
           auth: {:bearer, api_key},
           json: body,
           receive_timeout: 45_000
         ) do
      {:ok, %{status: status, body: %{"choices" => [%{"message" => message} | _]}}}
      when status in 200..299 ->
        handle_message(config, task, messages, tools, tool_context, round, message, started_at)

      {:ok, %{status: status, body: resp_body}} ->
        Logging.llm_io(:http_error, provider, task,
          provider: provider,
          task: task,
          model: model,
          service_host: service_host(base_url),
          http_status: status,
          duration_ms: System.monotonic_time(:millisecond) - started_at,
          reason: Logging.compact_inspect(resp_body)
        )

        raise "llm http error #{status}: #{inspect(resp_body)}"

      {:error, reason} ->
        Logging.llm_io(:failed, provider, task,
          provider: provider,
          task: task,
          model: model,
          service_host: service_host(base_url),
          duration_ms: System.monotonic_time(:millisecond) - started_at,
          reason: inspect(reason)
        )

        raise "llm request failed: #{inspect(reason)}"
    end
  end

  defp handle_message(config, task, messages, tools, tool_context, round, message, started_at) do
    %{model: model, base_url: base_url, provider: provider} = config

    case message do
      %{"tool_calls" => tool_calls}
      when is_list(tool_calls) and tool_calls != [] and round < @max_tool_rounds ->
        Logging.llm_io(:tool_calls, provider, task,
          provider: provider,
          task: task,
          model: model,
          service_host: service_host(base_url),
          duration_ms: System.monotonic_time(:millisecond) - started_at,
          tool_count: length(tool_calls),
          tools: Enum.map(tool_calls, &tool_call_summary/1)
        )

        tool_results = Enum.map(tool_calls, &ToolExecutor.execute(&1, tool_context))
        assistant_msg = %{"role" => "assistant", "tool_calls" => tool_calls}
        next_messages = messages ++ [assistant_msg | tool_results]
        complete_with_tools(config, task, next_messages, tools, tool_context, round + 1)

      %{"content" => content} when is_binary(content) ->
        Logging.llm_io(:finished, provider, task,
          provider: provider,
          task: task,
          model: model,
          service_host: service_host(base_url),
          http_status: 200,
          duration_ms: System.monotonic_time(:millisecond) - started_at,
          output_chars: String.length(content),
          output_preview: Logging.llm_text(content)
        )

        parse_response(task, content)

      %{"tool_calls" => _tool_calls} ->
        Logging.llm_io(:tool_calls_skipped, provider, task,
          provider: provider,
          task: task,
          reason: :max_rounds_reached,
          round: round
        )

        parse_response(task, "")

      _other ->
        raise "unexpected llm response message: #{inspect(message)}"
    end
  end

  @impl true
  def stream_complete(task, input) do
    %{api_key: api_key, model: model, base_url: base_url, provider: provider} =
      resolve_chat_provider()

    messages = messages(task, input)
    started_at = System.monotonic_time(:millisecond)

    Logging.llm_io(:stream_started, provider, task,
      provider: provider,
      task: task,
      model: model,
      service_host: service_host(base_url)
    )

    body = %{
      model: model,
      messages: messages,
      temperature: temperature(task),
      stream: true
    }

    Stream.resource(
      fn ->
        {:ok, resp} =
          Tools.http_post(chat_completions_url(base_url),
            auth: {:bearer, api_key},
            json: body,
            receive_timeout: 45_000,
            into: :self
          )

        %{
          buffer: "",
          resp: resp,
          provider: provider,
          task: task,
          model: model,
          started_at: started_at
        }
      end,
      fn state ->
        receive_sse_chunks(state)
      end,
      fn state ->
        Logging.llm_io(:stream_finished, state.provider, state.task,
          provider: state.provider,
          task: state.task,
          model: state.model,
          duration_ms: System.monotonic_time(:millisecond) - state.started_at
        )
      end
    )
  end

  # --- structured responses (investor identity extraction) ---

  @doc """
  returns a decoded structured response for the requested task.
  """
  def structured_response(task, input, opts \\ [])

  def structured_response(:investor_identity, transcript_text, opts)
      when is_binary(transcript_text) do
    payload = %{
      transcript: transcript_text,
      required_fields: ["name", "number", "firm"]
    }

    with {:ok, decoded} <-
           request_structured_response(
             :investor_identity_extract,
             Models.openai_identity(),
             Prompts.system!(:investor_identity_extraction),
             Jason.encode!(payload),
             investor_identity_schema(),
             opts,
             input_preview: payload,
             input_chars: String.length(transcript_text)
           ) do
      {:ok, InvestorIdentity.normalize(decoded)}
    end
  end

  def structured_response(task, _input, _opts) do
    {:error, {:unsupported_structured_response, task}}
  end

  # --- chat message building ---

  defp messages(:queued_continuation, input) do
    [
      %{role: "system", content: Prompts.system!(:queued_continuation)},
      %{role: "user", content: Jason.encode!(input)}
    ]
  end

  defp messages(:negotiation_advice, input) do
    [
      %{role: "system", content: Prompts.system!(:negotiation_advice)},
      %{role: "user", content: Jason.encode!(input)}
    ]
  end

  defp messages(:small_talk_reply, input) do
    [
      %{role: "system", content: Prompts.system!(:small_talk_reply)},
      %{role: "user", content: Jason.encode!(input)}
    ]
  end

  defp messages(:investor_turn, input) do
    research = Map.get(input, :research, [])
    pitch_phase = Map.get(input, :pitch_phase, "")
    system_prompt = Prompts.system!(:investor_turn) <> research_context(research) <> pitch_phase

    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: input |> Map.drop([:research, :pitch_phase]) |> Jason.encode!()}
    ]
  end

  defp messages(:investor_research_queries, input) do
    [
      %{role: "system", content: Prompts.system!(:investor_research_queries)},
      %{role: "user", content: Jason.encode!(input)}
    ]
  end

  defp messages(:turn_detection, input) do
    [
      %{role: "system", content: Prompts.system!(:turn_detection)},
      %{role: "user", content: Jason.encode!(turn_detection_input(input))}
    ]
  end

  # --- response parsing ---

  defp parse_response(:queued_continuation, content) do
    content
    |> String.split("\n", trim: true)
    |> parse_continuation()
  end

  defp parse_response(:investor_research_queries, content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(5)
  end

  defp parse_response(_task, content), do: String.trim(content)

  defp parse_continuation(lines) do
    lines
    |> Enum.map(&clean_candidate_text/1)
    |> Enum.reject(&skip_candidate_text?/1)
    |> List.first()
    |> case do
      nil -> ""
      text -> text
    end
  end

  defp clean_candidate_text(text) do
    text
    |> String.replace(~r/\*\*/, "")
    |> String.replace(~r/^[-•]\s*/, "")
    |> strip_after_speaker_prefix()
    |> String.replace(~r/^["']|["']$/, "")
    |> String.trim()
  end

  defp strip_after_speaker_prefix(text) do
    case Regex.run(~r/(?:small_talk_agent|small_talk|founder)\s*:\s*(.+)$/iu, text) do
      [_full, spoken_line] -> spoken_line
      nil -> text
    end
  end

  defp skip_candidate_text?(text) do
    cleaned = String.downcase(String.trim(text))
    cleaned == "" or cleaned == "---" or String.starts_with?(cleaned, "here are")
  end

  # --- sse streaming ---

  defp receive_sse_chunks(state) do
    receive do
      {_ref, {:data, data}} ->
        process_sse_data(state, data)

      {_ref, :done} ->
        flush_remaining(state)

      {_ref, {:error, reason}} ->
        flush_on_error(state, reason)
    after
      45_000 ->
        flush_on_error(state, :stream_timeout)
    end
  end

  defp process_sse_data(state, data) do
    tokens =
      data
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&parse_sse_line/1)
      |> Enum.join("")

    buffer = state.buffer <> tokens
    {sentences, remaining} = split_sentences(buffer)

    if sentences == [] do
      {[], %{state | buffer: remaining}}
    else
      {sentences, %{state | buffer: remaining}}
    end
  end

  defp flush_remaining(state) do
    text = String.trim(state.buffer)

    if text == "" do
      {:halt, state}
    else
      {[text], %{state | buffer: ""}}
    end
  end

  defp flush_on_error(state, reason) do
    text = String.trim(state.buffer)

    Logging.llm_io(:stream_error, :openai, :stream,
      reason: inspect(reason),
      buffer_chars: String.length(text)
    )

    if text == "" do
      {:halt, state}
    else
      {[text], %{state | buffer: ""}}
    end
  end

  defp parse_sse_line("data: [DONE]"), do: []

  defp parse_sse_line("data: " <> json) do
    case Jason.decode(json) do
      {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]}}
      when is_binary(content) ->
        [content]

      {:ok, _} ->
        []

      {:error, reason} ->
        Logging.llm_io(:stream_decode_error, :openai, :stream,
          reason: inspect(reason),
          json_preview: String.slice(json, 0, 100)
        )

        []
    end
  end

  defp parse_sse_line(_), do: []

  defp split_sentences(text) do
    case Regex.split(~r/(?<=[.!?])\s+/, text, include_captures: true, trim: true) do
      parts when length(parts) >= 2 ->
        {sentences, [remaining]} = Enum.split(parts, -1)

        completed =
          sentences
          |> Enum.join("")
          |> String.split(~r/(?<=[.!?])\s+/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {completed, remaining}

      _ ->
        {[], text}
    end
  end

  # --- provider config ---

  defp resolve_chat_provider do
    %{
      provider: :openai,
      api_key: Env.fetch!("OPENAI_API_KEY"),
      model: Models.openai_chat(),
      base_url: Env.get("OPENAI_BASE_URL", @base_url)
    }
  end

  defp chat_completions_url(base_url) do
    url = String.trim_trailing(base_url, "/")

    if String.ends_with?(url, "/v1") do
      "#{url}/chat/completions"
    else
      "#{url}/v1/chat/completions"
    end
  end

  # --- structured response internals ---

  defp request_structured_response(
         operation,
         default_model,
         system_prompt,
         user_content,
         schema,
         opts,
         log
       ) do
    if Env.present?("OPENAI_API_KEY") or Keyword.has_key?(opts, :api_key) do
      do_request_structured_response(
        operation,
        default_model,
        system_prompt,
        user_content,
        schema,
        opts,
        log
      )
    else
      Logger.warning("openai structured response skipped; OPENAI_API_KEY missing",
        operation: operation
      )

      {:error, :missing_openai_api_key}
    end
  end

  defp do_request_structured_response(
         operation,
         default_model,
         system_prompt,
         user_content,
         schema,
         opts,
         log
       ) do
    api_key = Keyword.get_lazy(opts, :api_key, fn -> Env.fetch!("OPENAI_API_KEY") end)
    model = Keyword.get(opts, :model, default_model)
    base_url = Keyword.get(opts, :base_url, Env.get("OPENAI_BASE_URL", @base_url))
    http_post = Keyword.get(opts, :http_post, &Tools.http_post/2)
    started_at = System.monotonic_time(:millisecond)

    Logging.provider_call(:started, :openai, operation,
      model: model,
      input_chars: Keyword.get(log, :input_chars),
      system_prompt: Logging.llm_text(system_prompt),
      context: Logging.llm_text(user_content),
      input_preview: Logging.compact_inspect(Keyword.get(log, :input_preview))
    )

    case http_post.(responses_url(base_url),
           auth: {:bearer, api_key},
           json: structured_request_body(model, system_prompt, user_content, schema),
           receive_timeout: Keyword.get(opts, :receive_timeout, 12_000)
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        output = output_text(body)

        case Jason.decode(output || "{}") do
          {:ok, decoded} ->
            Logging.provider_call(:finished, :openai, operation,
              model: model,
              duration_ms: System.monotonic_time(:millisecond) - started_at,
              http_status: status,
              output: Logging.llm_text(output),
              extracted_fields: present_fields(decoded)
            )

            {:ok, decoded}

          {:error, reason} ->
            Logging.provider_call(:failed, :openai, operation,
              model: model,
              duration_ms: System.monotonic_time(:millisecond) - started_at,
              reason: inspect(reason),
              output: Logging.llm_text(output)
            )

            {:error, reason}
        end

      {:ok, %{status: status, body: body}} ->
        Logging.provider_call(:http_error, :openai, operation,
          model: model,
          duration_ms: System.monotonic_time(:millisecond) - started_at,
          http_status: status,
          reason: Logging.compact_inspect(body)
        )

        {:error, {:http_error, status}}

      {:error, reason} ->
        Logging.provider_call(:failed, :openai, operation,
          model: model,
          duration_ms: System.monotonic_time(:millisecond) - started_at,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp structured_request_body(model, system_prompt, user_content, schema) do
    %{
      model: model,
      input: [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_content}
      ],
      text: %{
        format: schema
      }
    }
  end

  defp investor_identity_schema do
    %{
      type: "json_schema",
      name: "investor_identity",
      strict: true,
      schema: %{
        type: "object",
        additionalProperties: false,
        required: ["name", "number", "firm"],
        properties: %{
          name: %{type: "string"},
          number: %{type: "string"},
          firm: %{type: "string"}
        }
      }
    }
  end

  defp responses_url(base_url) do
    base_url = String.trim_trailing(base_url, "/")

    if String.ends_with?(base_url, "/v1") do
      "#{base_url}/responses"
    else
      "#{base_url}/v1/responses"
    end
  end

  defp output_text(%{"output_text" => text}) when is_binary(text), do: text

  defp output_text(%{"output" => output}) when is_list(output) do
    output
    |> Enum.flat_map(&Map.get(&1, "content", []))
    |> Enum.find_value(fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      _other -> nil
    end)
  end

  defp output_text(_body), do: "{}"

  defp present_fields(decoded) do
    decoded
    |> InvestorIdentity.normalize()
    |> Enum.filter(fn {_key, value} -> value not in [nil, ""] end)
    |> Enum.map(fn {key, _value} -> key end)
  end

  # --- shared helpers ---

  defp temperature(:queued_continuation), do: 0.7
  defp temperature(:small_talk_reply), do: 0.65
  defp temperature(:investor_turn), do: 0.7
  defp temperature(:negotiation_advice), do: 0.35
  defp temperature(:investor_research_queries), do: 0.5
  defp temperature(:turn_detection), do: 0.0

  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools), do: Map.put(body, :tools, tools)

  defp tool_call_summary(%{"function" => %{"name" => name, "arguments" => args}}) do
    "#{name}(#{Logging.compact_text(args)})"
  end

  defp tool_call_summary(call), do: Logging.compact_inspect(call)

  defp tool_context(%{call_id: call_id}) when is_binary(call_id), do: %{call_id: call_id}
  defp tool_context(_input), do: %{}

  defp log_started(config, task, input, messages) do
    %{model: model, base_url: base_url, provider: provider} = config
    system_prompt = message_content(messages, "system")
    context = message_content(messages, "user")

    Logging.llm_io(:started, provider, task,
      provider: provider,
      task: task,
      model: model,
      service_host: service_host(base_url),
      input_chars: input_size(input),
      system_prompt_chars: String.length(system_prompt),
      context_chars: String.length(context),
      system_prompt: Logging.llm_text(system_prompt),
      context: Logging.llm_text(context),
      input_preview: Logging.compact_inspect(input)
    )
  end

  defp service_host(base_url) do
    case URI.parse(base_url) do
      %{host: host} when is_binary(host) -> host
      _other -> base_url
    end
  end

  defp input_size(input) do
    input
    |> Logging.compact_inspect()
    |> String.length()
  end

  defp message_content(messages, role) do
    messages
    |> Enum.find_value("", fn
      %{role: ^role, content: content} when is_binary(content) -> content
      _other -> nil
    end)
  end

  defp research_context(research) when is_list(research) and research != [] do
    entries =
      Enum.map_join(research, "\n", fn r ->
        title = r[:title] || r["title"] || ""
        snippet = r[:snippet] || r["snippet"] || ""
        "- #{title}: #{snippet}"
      end)

    """

    you have done background research on this founder's space. use these findings to ask
    informed, specific questions. reference concrete numbers, competitors, and market data
    when challenging claims. do not reveal that you searched — frame your knowledge as
    "i've been looking at this space" or "from what i understand about the market".

    research findings:
    #{entries}
    """
  end

  defp research_context(_), do: ""

  defp turn_detection_input(input) do
    input
    |> Map.take([:role, :text, :silence_ms, :stable_words])
    |> Map.put(:heuristic, heuristic_for_prompt(input[:heuristic]))
  end

  defp heuristic_for_prompt(nil), do: nil

  defp heuristic_for_prompt(heuristic) do
    %{
      end_probability: heuristic[:end_probability],
      should_wait: heuristic[:should_wait?],
      should_reply: heuristic[:should_reply?],
      reason: to_string(heuristic[:reason])
    }
  end
end
