defmodule Negotiator.Retrieval.Moss do
  @moduledoc """
  moss-backed retrieval for low-latency negotiation context.
  """

  @behaviour Negotiator.Retrieval

  alias Negotiator.{Env, Tools}

  require Logger

  @impl true
  def search(query, opts \\ []) do
    case search_strict(query, opts) do
      {:ok, docs} ->
        docs

      {:error, reason} ->
        Logger.warning("moss retrieval failed; returning no context",
          reason: inspect(reason),
          query_chars: String.length(to_string(query || ""))
        )

        []
    end
  end

  @doc """
  returns true when moss credentials and an index name are present.
  """
  def configured? do
    Env.present?("MOSS_PROJECT_ID") and Env.present?("MOSS_INDEX_NAME") and
      (Env.present?("MOSS_PROJECT_KEY") or Env.present?("MOSS_API_KEY"))
  end

  @doc """
  adds documents to the configured moss index.
  """
  def add_docs(docs, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)
    docs = List.wrap(docs)

    with {:ok, state} <- client_state(),
         index_name <- Keyword.get(opts, :index_name, state.index_name),
         {:ok, mutation} <- add_or_create(state, index_name, docs) do
      Logger.info("moss documents added",
        index_name: index_name,
        docs: length(docs),
        doc_contents: Enum.map(docs, fn d -> %{id: d.id, text: d.text, metadata: d.metadata} end),
        duration_ms: System.monotonic_time(:millisecond) - started_at
      )

      {:ok, mutation}
    else
      {:error, reason} ->
        Logger.warning(
          "moss document add failed: #{inspect(reason)} docs=#{inspect(Enum.map(docs, fn d -> %{id: d.id, metadata: d.metadata} end), limit: 4, printable_limit: 300)}"
        )

        {:error, reason}
    end
  rescue
    error ->
      Logger.warning(
        "moss document add raised: #{Exception.message(error)} docs=#{length(docs)}"
      )

      {:error, error}
  end

  @doc """
  searches moss without falling back to the local knowledge bank.
  """
  def search_strict(query, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)
    limit = Keyword.get(opts, :limit, 3)

    Logger.info("moss retrieval started",
      index_name: Env.get("MOSS_INDEX_NAME"),
      limit: limit,
      query_chars: String.length(to_string(query || ""))
    )

    do_search_strict(query, opts, started_at)
  end

  defp do_search_strict(query, opts, started_at) do
    with {:ok, state} <- client_state(),
         {:ok, state} <- ensure_loaded(state),
         {:ok, result} <- query_index(state, query, opts) do
      docs = normalize_docs(result.docs)

      Logger.info("moss retrieval finished",
        index_name: state.index_name,
        docs: length(docs),
        duration_ms: System.monotonic_time(:millisecond) - started_at
      )

      {:ok, docs}
    else
      {:error, reason} ->
        Logger.warning("moss retrieval failed",
          reason: inspect(reason),
          duration_ms: System.monotonic_time(:millisecond) - started_at
        )

        {:error, reason}
    end
  rescue
    error ->
      Logger.warning("moss retrieval raised",
        reason: inspect(error),
        duration_ms: System.monotonic_time(:millisecond) - started_at
      )

      {:error, error}
  end

  @doc """
  lists cloud indexes for the configured moss project.
  """
  def list_indexes(opts \\ []) do
    client_module =
      Keyword.get(
        opts,
        :client_module,
        Application.get_env(:negotiator, :moss_client_module, Moss.Client)
      )

    base_url = Env.get("MOSS_BASE_URL")

    with {:ok, client} <-
           Tools.moss_client_new(
             client_module,
             Env.fetch!("MOSS_PROJECT_ID"),
             moss_project_key(),
             client_opts(%{base_url: base_url})
           ),
         {:ok, indexes} <- Tools.moss_client_list_indexes(client_module, client) do
      Logger.info("moss indexes listed", indexes: length(indexes))
      {:ok, Enum.map(indexes, &normalize_index/1)}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @doc false
  def reset do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  end

  defp client_state do
    ensure_agent()

    Agent.get_and_update(__MODULE__, fn
      %{client: nil} = state ->
        case Tools.moss_client_new(
               state.client_module,
               state.project_id,
               state.project_key,
               client_opts(state)
             ) do
          {:ok, client} ->
            state = %{state | client: client}
            {{:ok, state}, state}

          {:error, reason} ->
            {{:error, reason}, state}
        end

      state ->
        {{:ok, state}, state}
    end)
  end

  defp ensure_loaded(state) do
    if MapSet.member?(state.loaded_indexes, state.index_name) do
      {:ok, state}
    else
      case Tools.moss_client_load_index(
             state.client_module,
             state.client,
             state.index_name,
             state.load_opts
           ) do
        {:ok, _info} ->
          update_loaded_index(state.index_name)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp update_loaded_index(index_name) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = %{state | loaded_indexes: MapSet.put(state.loaded_indexes, index_name)}
      {{:ok, state}, state}
    end)
  end

  defp query_index(state, query, opts) do
    limit = Keyword.get(opts, :limit, 3)
    alpha = Keyword.get(opts, :alpha, moss_alpha())

    Tools.moss_client_query(state.client_module, state.client, state.index_name, query,
      top_k: limit,
      alpha: alpha
    )
  end

  defp add_or_create(state, index_name, docs) do
    case Tools.moss_client_add_docs(state.client_module, state.client, index_name, docs,
           upsert: true
         ) do
      {:ok, mutation} ->
        {:ok, mutation}

      {:error, reason} when is_binary(reason) ->
        if String.contains?(reason, "INDEX_NOT_FOUND") or String.contains?(reason, "404") do
          Logger.info("moss index not found, creating", index_name: index_name)
          state.client_module.create_index(state.client, index_name, docs)
        else
          {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_agent do
    case Agent.start_link(fn -> config() end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp config do
    %{
      project_id: Env.fetch!("MOSS_PROJECT_ID"),
      project_key: moss_project_key(),
      index_name: Env.fetch!("MOSS_INDEX_NAME"),
      base_url: Env.get("MOSS_BASE_URL"),
      load_opts: [auto_refresh: Env.get("MOSS_AUTO_REFRESH", "true") in ["1", "true"]],
      loaded_indexes: MapSet.new(),
      client: nil,
      client_module: Application.get_env(:negotiator, :moss_client_module, Moss.Client)
    }
  end

  defp client_opts(%{base_url: nil}), do: []
  defp client_opts(%{base_url: ""}), do: []
  defp client_opts(%{base_url: base_url}), do: [base_url: base_url]

  defp moss_project_key do
    case Env.get("MOSS_PROJECT_KEY") || Env.get("MOSS_API_KEY") do
      value when is_binary(value) and value != "" -> value
      _missing -> Env.fetch!("MOSS_PROJECT_KEY")
    end
  end

  defp moss_alpha do
    "MOSS_ALPHA"
    |> Env.get("0.8")
    |> Float.parse()
    |> case do
      {alpha, _rest} -> alpha
      :error -> 0.8
    end
  end

  defp normalize_docs(docs) do
    docs
    |> List.wrap()
    |> Enum.map(&normalize_doc/1)
  end

  defp normalize_doc(%_{} = doc), do: doc |> Map.from_struct() |> normalize_doc()

  defp normalize_doc(doc) when is_map(doc) do
    %{
      id: doc[:id] || doc["id"],
      text: doc[:text] || doc["text"],
      score: doc[:score] || doc["score"],
      metadata: doc[:metadata] || doc["metadata"] || %{},
      source: :moss
    }
  end

  defp normalize_index(%_{} = index), do: index |> Map.from_struct() |> normalize_index()

  defp normalize_index(index) when is_map(index) do
    %{
      name: index[:name] || index["name"],
      status: index[:status] || index["status"],
      doc_count: index[:doc_count] || index["doc_count"],
      updated_at: index[:updated_at] || index["updated_at"],
      model: index[:model] || index["model"]
    }
  end
end
