defmodule Negotiator.Tools do
  @moduledoc """
  central boundary for provider/tool calls made by the voice runtime.
  """

  @doc """
  calls the configured llm provider.
  """
  def llm_complete(llm, task, input), do: llm.complete(task, input)

  @doc """
  calls the configured speech synthesis provider.
  """
  def synthesize_voice(voice, text, opts), do: voice.synthesize(text, opts)

  @doc """
  calls the configured research provider.
  """
  def research_search(research, query), do: research.search(query)

  @doc """
  writes documents into moss.
  """
  def moss_add_docs(documents, opts \\ []), do: Negotiator.Retrieval.Moss.add_docs(documents, opts)

  @doc """
  creates a moss client.
  """
  def moss_client_new(client_module, project_id, project_key, opts) do
    client_module.new(project_id, project_key, opts)
  end

  @doc """
  lists moss indexes through a moss client.
  """
  def moss_client_list_indexes(client_module, client) do
    client_module.list_indexes(client)
  end

  @doc """
  adds documents through a moss client.
  """
  def moss_client_add_docs(client_module, client, index_name, docs, opts) do
    client_module.add_docs(client, index_name, docs, opts)
  end

  @doc """
  loads a moss index through a moss client.
  """
  def moss_client_load_index(client_module, client, index_name, opts) do
    client_module.load_index(client, index_name, opts)
  end

  @doc """
  queries a moss index through a moss client.
  """
  def moss_client_query(client_module, client, index_name, query, opts) do
    client_module.query(client, index_name, query, opts)
  end

  @doc """
  performs an external http post.
  """
  def http_post(url, opts), do: Req.post(url, opts)

  @doc """
  performs an external http get.
  """
  def http_get(opts) when is_list(opts), do: Req.get(opts)
  def http_get(url, opts), do: Req.get(url, opts)

  @doc """
  runs an external command.
  """
  def run_command(command, args, opts \\ []), do: System.cmd(command, args, opts)

  @doc """
  answers a phone call through the configured telephony provider.
  """
  def answer_call(telephony, call_id), do: telephony.answer(call_id)

  @doc """
  starts bidirectional media streaming through the configured telephony provider.
  """
  def start_streaming(telephony, call_id, opts \\ []),
    do: telephony.start_streaming(call_id, opts)

  @doc """
  starts in-call transcription through the configured telephony provider.
  """
  def start_transcription(telephony, call_id, opts \\ []),
    do: telephony.start_transcription(call_id, opts)

  @doc """
  places the real outbound investor leg.
  """
  def dial_investor(telephony, parent_call_id, investor_identity),
    do: telephony.dial_investor(parent_call_id, investor_identity)

  @doc """
  bridges the founder and investor call legs.
  """
  def bridge_calls(telephony, call_id, call_id_to_bridge_with),
    do: telephony.bridge(call_id, call_id_to_bridge_with)

end
