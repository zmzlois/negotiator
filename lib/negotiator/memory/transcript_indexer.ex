defmodule Negotiator.TranscriptIndexer do
  @moduledoc """
  writes final transcript turns into moss for cross-call retrieval.
  """

  alias Moss.DocumentInfo
  alias Negotiator.{Env, Repo, Tools, TranscriptTurn}

  require Logger

  @doc """
  indexes one saved sqlite transcript turn in moss.
  """
  def index_turn(%TranscriptTurn{} = turn) do
    cond do
      disabled?() ->
        mark_index_status(turn, "disabled")
        {:ok, :disabled}

      not convo_index_configured?() ->
        mark_index_status(turn, "not_configured")
        {:ok, :moss_not_configured}

      true ->
        document = document(turn)

        case Tools.moss_add_docs([document], index_name: convo_index_name()) do
          {:ok, mutation} ->
            mark_index_status(turn, "indexed",
              document_id: document.id,
              indexed_at: DateTime.utc_now()
            )

            Logger.debug("transcript turn indexed in moss",
              call_id: turn.call_id,
              turn_id: turn.id,
              sequence: turn.sequence,
              role: turn.role
            )

            {:ok, mutation}

          {:error, reason} ->
            mark_index_status(turn, "failed",
              document_id: document.id,
              error: inspect(reason, limit: 8, printable_limit: 240)
            )

            Logger.warning(
              "transcript turn moss indexing failed: #{inspect(reason)} call_id=#{turn.call_id} role=#{turn.role} doc_id=#{document.id}"
            )

            {:error, reason}
        end
    end
  rescue
    error ->
      mark_index_status(turn, "failed", error: Exception.message(error))

      Logger.warning(
        "transcript turn moss indexing raised: #{Exception.message(error)} call_id=#{turn.call_id} role=#{turn.role}"
      )

      {:error, error}
  end

  @doc """
  builds the moss document for one transcript turn.
  """
  def document(%TranscriptTurn{} = turn) do
    %DocumentInfo{
      id: document_id(turn),
      text: document_text(turn),
      metadata: document_metadata(turn)
    }
  end

  defp disabled? do
    Env.get("MOSS_TRANSCRIPT_INDEXING_ENABLED", "true") in ["0", "false", "FALSE"]
  end

  defp convo_index_name do
    Env.get("MOSS_CONVO_INDEX_NAME", "conversation")
  end

  defp convo_index_configured? do
    Env.present?("MOSS_PROJECT_ID") and
      Env.present?("MOSS_CONVO_INDEX_NAME") and
      (Env.present?("MOSS_PROJECT_KEY") or Env.present?("MOSS_API_KEY"))
  end

  defp mark_index_status(%TranscriptTurn{} = turn, status, opts \\ []) do
    attrs = %{
      moss_document_id: Keyword.get(opts, :document_id),
      moss_index_status: status,
      moss_index_error: Keyword.get(opts, :error),
      moss_indexed_at: Keyword.get(opts, :indexed_at)
    }

    turn
    |> TranscriptTurn.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, _turn} ->
        :ok

      {:error, changeset} ->
        Logger.warning("transcript turn moss index status update rejected",
          call_id: turn.call_id,
          turn_id: turn.id,
          status: status,
          errors: inspect(changeset.errors)
        )
    end
  rescue
    error ->
      Logger.warning("transcript turn moss index status update failed",
        call_id: turn.call_id,
        turn_id: turn.id,
        status: status,
        reason: Exception.message(error)
      )
  end

  defp document_id(turn) do
    identity =
      [turn.investor_name, turn.investor_number, turn.investor_firm]
      |> Enum.map(&id_part/1)
      |> Enum.reject(&(&1 == "unknown"))
      |> case do
        [] -> "unknown-investor"
        parts -> Enum.join(parts, "-")
      end

    sequence = turn.sequence || turn.id || "unknown"

    "transcript:#{identity}:call:#{id_part(turn.call_id)}:turn:#{sequence}"
  end

  defp document_text(turn) do
    [
      "investor name: #{display(turn.investor_name)}",
      "investor number: #{display(turn.investor_number)}",
      "investor firm: #{display(turn.investor_firm)}",
      "role: #{display(turn.role)}",
      "room: #{display(turn.room)}",
      "source: #{display(turn.source)}",
      "transcript: #{turn.text}"
    ]
    |> Enum.join("\n")
  end

  defp document_metadata(turn) do
    stringify_metadata(%{
      "source" => "transcript_turn",
      "kind" => "call_transcript_turn",
      "call_id" => turn.call_id,
      "turn_id" => turn.id,
      "sequence" => turn.sequence,
      "role" => turn.role,
      "room" => turn.room,
      "llm_or_human_source" => turn.source,
      "investor_name" => turn.investor_name,
      "investor_number" => turn.investor_number,
      "investor_firm" => turn.investor_firm,
      "occurred_at" => format_datetime(turn.occurred_at)
    })
  end

  defp stringify_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, metadata_value(value)} end)
  end

  defp metadata_value(values) when is_list(values), do: Enum.map_join(values, ",", &to_string/1)
  defp metadata_value(value), do: to_string(value)

  defp display(value) when is_binary(value) and value != "", do: value
  defp display(_value), do: "unknown"

  defp id_part(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9+]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      part -> part
    end
  end

  defp id_part(value) when is_integer(value), do: Integer.to_string(value)
  defp id_part(_value), do: "unknown"

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(_datetime), do: nil
end
