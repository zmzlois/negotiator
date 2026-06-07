defmodule Negotiator.Memory.MossSession do
  @moduledoc """
  per-call moss session for local in-memory transcript indexing and retrieval.
  each call gets its own session — no cloud round-trips during the call.
  sessions are pushed to cloud on call end for cross-call persistence.
  """

  alias Negotiator.{Env, Logging}

  require Logger

  @session_table :negotiator_moss_sessions

  def ensure_table do
    if :ets.whereis(@session_table) == :undefined do
      try do
        :ets.new(@session_table, [:named_table, :public, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  def start(call_id) when is_binary(call_id) do
    case lookup(call_id) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        case create_session(call_id) do
          {:ok, pid} ->
            :ets.insert(@session_table, {call_id, pid})
            {:ok, pid}

          {:error, reason} ->
            Logger.warning("moss session failed to start",
              call_id: call_id,
              reason: inspect(reason)
            )

            {:error, reason}
        end
    end
  end

  def index_transcript(call_id, turn) when is_binary(call_id) and is_map(turn) do
    case ensure_session(call_id) do
      {:ok, pid} ->
        doc = transcript_document(call_id, turn)

        case Moss.Session.add_docs(pid, [doc], upsert: true) do
          {:ok, counts} ->
            {:ok, counts}

          {:error, reason} ->
            Logger.warning("moss session index failed",
              call_id: call_id,
              role: turn[:role],
              reason: inspect(reason)
            )

            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def search(call_id, query, opts \\ []) when is_binary(call_id) and is_binary(query) do
    case lookup(call_id) do
      {:ok, pid} ->
        top_k = Keyword.get(opts, :limit, 5)
        filter = build_filter(opts)

        Logging.provider_call(:started, :moss_session, :search,
          call_id: call_id,
          query_chars: String.length(query),
          filter: inspect(filter)
        )

        started_at = System.monotonic_time(:millisecond)

        case Moss.Session.query(pid, query, top_k: top_k, filter: filter) do
          {:ok, result} ->
            docs = normalize_results(result)

            Logging.provider_call(:finished, :moss_session, :search,
              call_id: call_id,
              result_count: length(docs),
              duration_ms: System.monotonic_time(:millisecond) - started_at
            )

            {:ok, docs}

          {:error, reason} ->
            Logging.provider_call(:failed, :moss_session, :search,
              call_id: call_id,
              reason: inspect(reason),
              duration_ms: System.monotonic_time(:millisecond) - started_at
            )

            {:error, reason}
        end

      :not_found ->
        {:ok, []}
    end
  end

  def load_founder_index(call_id, phone) when is_binary(call_id) and is_binary(phone) do
    index_name = founder_index_name(phone)

    case ensure_session(call_id) do
      {:ok, pid} ->
        case Moss.Session.load_index(pid, index_name) do
          {:ok, doc_count} ->
            Logger.info("founder knowledge loaded",
              call_id: call_id,
              founder_phone: phone,
              index_name: index_name,
              docs: doc_count
            )

            {:ok, doc_count}

          {:error, reason} ->
            Logger.info("founder knowledge not found (first call)",
              call_id: call_id,
              founder_phone: phone,
              reason: inspect(reason)
            )

            {:ok, 0}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stop(call_id, founder_phone \\ nil) when is_binary(call_id) do
    case lookup(call_id) do
      {:ok, pid} ->
        push_founder_index(call_id, pid, founder_phone)
        if Process.alive?(pid), do: GenServer.stop(pid)
        :ets.delete(@session_table, call_id)
        :ok

      :not_found ->
        :ok
    end
  end

  defp lookup(call_id) do
    case :ets.lookup(@session_table, call_id) do
      [{^call_id, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: :not_found

      _ ->
        :not_found
    end
  end

  defp ensure_session(call_id) do
    case lookup(call_id) do
      {:ok, pid} -> {:ok, pid}
      :not_found -> start(call_id)
    end
  end

  def warm_model do
    if configured?() do
      Logger.info("moss session warming embedding model")
      started_at = System.monotonic_time(:millisecond)

      with {:ok, pid} <-
             Moss.Session.start_link(
               name: "warmup",
               model_id: Env.get("MOSS_SESSION_MODEL", "moss-minilm"),
               project_id: Env.fetch!("MOSS_PROJECT_ID"),
               project_key: moss_project_key()
             ),
           {:ok, :ok} <- Moss.Session.load_model(pid) do
        GenServer.stop(pid)

        Logger.info("moss session model warmed",
          duration_ms: System.monotonic_time(:millisecond) - started_at
        )

        :ok
      else
        {:error, reason} ->
          Logger.warning("moss session model warmup failed", reason: inspect(reason))
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp create_session(call_id) do
    if configured?() do
      session_name = "call:#{call_id}"

      Moss.Session.start_link(
        name: session_name,
        model_id: Env.get("MOSS_SESSION_MODEL", "moss-minilm"),
        project_id: Env.fetch!("MOSS_PROJECT_ID"),
        project_key: moss_project_key()
      )
    else
      {:error, :moss_not_configured}
    end
  end

  defp configured? do
    Env.present?("MOSS_PROJECT_ID") and
      (Env.present?("MOSS_PROJECT_KEY") or Env.present?("MOSS_API_KEY"))
  end

  defp moss_project_key do
    Env.get("MOSS_PROJECT_KEY") || Env.get("MOSS_API_KEY", "")
  end

  defp push_founder_index(_call_id, _pid, nil), do: :ok

  defp push_founder_index(call_id, pid, phone) do
    index_name = founder_index_name(phone)

    case Moss.Session.push_index(pid) do
      {:ok, _result} ->
        Logger.info("founder knowledge saved",
          call_id: call_id,
          founder_phone: phone,
          index_name: index_name
        )

      {:error, reason} ->
        Logger.warning("founder knowledge push failed",
          call_id: call_id,
          founder_phone: phone,
          reason: inspect(reason)
        )
    end
  rescue
    error ->
      Logger.warning("founder knowledge push raised",
        call_id: call_id,
        reason: Exception.message(error)
      )
  end

  defp founder_index_name(phone) do
    sanitized = phone |> String.replace(~r/[^0-9+]/, "") |> String.trim_leading("+")
    "founder:#{sanitized}"
  end

  defp transcript_document(call_id, turn) do
    role = to_string(turn[:role] || "unknown")
    room = to_string(turn[:room] || "unknown")
    sequence = turn[:sequence] || 0

    %Moss.DocumentInfo{
      id: "#{call_id}:#{role}:#{sequence}",
      text: to_string(turn[:text] || ""),
      metadata: %{
        "role" => role,
        "room" => room,
        "call_id" => call_id,
        "sequence" => to_string(sequence)
      }
    }
  end

  defp build_filter(opts) do
    role = Keyword.get(opts, :role)

    case role do
      nil -> nil
      role -> %{"role" => to_string(role)}
    end
  end

  defp normalize_results(%{docs: docs}) when is_list(docs) do
    Enum.map(docs, fn doc ->
      %{
        id: doc.id,
        text: doc.text,
        score: doc.score,
        metadata: doc.metadata || %{},
        source: :moss_session
      }
    end)
  end

  defp normalize_results(_), do: []
end
