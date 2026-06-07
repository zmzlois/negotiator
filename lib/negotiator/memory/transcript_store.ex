defmodule Negotiator.TranscriptStore do
  @moduledoc """
  writes final transcript turns to sqlite without blocking call orchestration decisions.
  """

  alias Negotiator.{InvestorIdentity, Repo, TranscriptIndexer, TranscriptTurn}

  import Ecto.Query

  require Logger

  @default_history_limit 12

  @doc """
  persists one transcript turn and logs failures without crashing the call.
  """
  def save_turn(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    %TranscriptTurn{}
    |> TranscriptTurn.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, turn} ->
        index_turn_async(turn)

        Logger.debug("transcript turn persisted",
          call_id: turn.call_id,
          sequence: turn.sequence,
          role: turn.role,
          room: turn.room,
          source: turn.source
        )

        {:ok, turn}

      {:error, changeset} ->
        Logger.warning("transcript turn persistence rejected",
          call_id: attrs[:call_id],
          role: attrs[:role],
          errors: inspect(changeset.errors)
        )

        {:error, changeset}
    end
  rescue
    error ->
      Logger.warning("transcript turn persistence failed",
        call_id: attrs[:call_id],
        role: attrs[:role],
        reason: Exception.message(error)
      )

      {:error, error}
  end

  @doc """
  returns recent prior transcript turns for an investor identity.
  """
  def recent_for_investor(identity, opts \\ []) do
    identity = InvestorIdentity.normalize(identity)
    limit = Keyword.get(opts, :limit, @default_history_limit)
    exclude_call_id = Keyword.get(opts, :exclude_call_id)

    case identity_filter(identity) do
      nil ->
        []

      filter ->
        TranscriptTurn
        |> where(^filter)
        |> exclude_call_if_present(exclude_call_id)
        |> order_by([turn], desc: turn.occurred_at, desc: turn.id)
        |> limit(^limit)
        |> Repo.all()
        |> Enum.reverse()
    end
  rescue
    error ->
      Logger.warning("prior investor transcript lookup failed",
        investor_name: identity.name,
        investor_number: identity.number,
        investor_firm: identity.firm,
        reason: Exception.message(error)
      )

      []
  end

  defp normalize_attrs(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {key, normalize_value(key, value)} end)
    |> Map.update(:metadata, %{}, &Map.new/1)
    |> Map.put_new(:moss_index_status, "pending")
    |> put_investor_identity()
  end

  defp identity_filter(identity) do
    filters =
      []
      |> add_filter_if_present(identity.number, fn value ->
        dynamic([turn], turn.investor_number == ^value)
      end)
      |> add_filter_if_present(identity.name, fn value ->
        if identity.firm do
          firm = identity.firm
          dynamic([turn], turn.investor_name == ^value and turn.investor_firm == ^firm)
        else
          dynamic([turn], turn.investor_name == ^value)
        end
      end)

    case filters do
      [] ->
        nil

      [filter | rest] ->
        Enum.reduce(rest, filter, fn next_filter, acc ->
          dynamic([turn], ^acc or ^next_filter)
        end)
    end
  end

  defp add_filter_if_present(filters, nil, _fun), do: filters
  defp add_filter_if_present(filters, "", _fun), do: filters
  defp add_filter_if_present(filters, value, fun), do: [fun.(value) | filters]

  defp exclude_call_if_present(query, nil), do: query
  defp exclude_call_if_present(query, ""), do: query

  defp exclude_call_if_present(query, call_id) do
    where(query, [turn], turn.call_id != ^call_id)
  end

  defp put_investor_identity(attrs) do
    identity = InvestorIdentity.normalize(Map.get(attrs, :investor_identity, %{}))

    attrs
    |> Map.drop([:investor_identity])
    |> Map.put(:investor_name, identity.name)
    |> Map.put(:investor_number, identity.number)
    |> Map.put(:investor_firm, identity.firm)
    |> Map.update(:metadata, InvestorIdentity.metadata(identity), fn metadata ->
      Map.merge(Map.new(metadata), InvestorIdentity.metadata(identity))
    end)
  end

  defp index_turn_async(%TranscriptTurn{} = turn) do
    case Process.whereis(Negotiator.ProviderTaskSupervisor) do
      nil ->
        TranscriptIndexer.index_turn(turn)

      _pid ->
        case Task.Supervisor.start_child(Negotiator.ProviderTaskSupervisor, fn ->
               TranscriptIndexer.index_turn(turn)
             end) do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            Logger.warning("transcript turn moss indexing could not start",
              call_id: turn.call_id,
              turn_id: turn.id,
              reason: inspect(reason)
            )
        end
    end
  end

  defp normalize_value(key, value) when key in [:role, :room, :source] and is_atom(value) do
    Atom.to_string(value)
  end

  defp normalize_value(_key, value), do: value
end
