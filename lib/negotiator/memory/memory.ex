defmodule Negotiator.Memory do
  @moduledoc """
  primary store for live call state shared between the call session and provider jobs.
  writes are serialized through the genserver to prevent read-modify-write races.
  reads go directly to ets for speed.
  """

  use GenServer

  alias Negotiator.Memory.MossSession
  alias Negotiator.Transcript

  @table :negotiator_call_contexts
  @supervisor Negotiator.ProviderTaskSupervisor

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ensure_table()
    MossSession.ensure_table()
    {:ok, %{}}
  end

  def write(call_id, changes) when is_binary(call_id) and is_map(changes) do
    GenServer.call(__MODULE__, {:write, call_id, changes})
  end

  @doc """
  atomically appends items to a list field in memory.
  prevents the read-modify-write race that occurs when multiple
  provider jobs append to the same list concurrently.
  """
  def append_to_list(call_id, key, items) when is_binary(call_id) and is_list(items) do
    GenServer.call(__MODULE__, {:append_to_list, call_id, key, items})
  end

  def drop(call_id, founder_phone \\ nil) when is_binary(call_id) do
    MossSession.stop(call_id, founder_phone)
    GenServer.call(__MODULE__, {:drop, call_id})
  end

  @impl true
  def handle_call({:write, call_id, changes}, _from, state) do
    do_write(call_id, changes)
    {:reply, :ok, state}
  end

  def handle_call({:append_to_list, call_id, key, items}, _from, state) do
    existing = do_field(call_id, key) || []
    do_write(call_id, %{key => existing ++ items})
    {:reply, :ok, state}
  end

  def handle_call({:drop, call_id}, _from, state) do
    :ets.delete(@table, call_id)
    {:reply, :ok, state}
  end

  def context(call_id) when is_binary(call_id) do
    do_context(call_id)
  end

  def field(call_id, key) when is_binary(call_id) do
    do_field(call_id, key)
  end

  defp do_context(call_id) do
    case :ets.lookup(@table, call_id) do
      [{^call_id, ctx}] -> ctx
      [] -> nil
    end
  end

  defp do_field(call_id, key) do
    case do_context(call_id) do
      %{} = ctx -> Map.get(ctx, key)
      nil -> nil
    end
  end

  defp do_write(call_id, changes) do
    case :ets.lookup(@table, call_id) do
      [{^call_id, existing}] -> :ets.insert(@table, {call_id, Map.merge(existing, changes)})
      [] -> :ets.insert(@table, {call_id, Map.merge(%{call_id: call_id}, changes)})
    end
  end

  # -- typed accessors for provider jobs --

  def mode(call_id), do: field(call_id, :mode)
  def transcript(call_id), do: field(call_id, :transcript) || []
  def candidates(call_id), do: field(call_id, :candidates) || []
  def response_queue(call_id), do: field(call_id, :response_queue) || []
  def response_lifecycle(call_id), do: field(call_id, :response_lifecycle)
  def sequence(call_id), do: field(call_id, :sequence) || 0
  def events(call_id), do: field(call_id, :events) || []
  def orchestration(call_id), do: field(call_id, :orchestration)
  def prediction_checkpoint(call_id), do: field(call_id, :prediction_checkpoint) || 0
  def briefing(call_id), do: field(call_id, :briefing)
  def investor_research(call_id), do: field(call_id, :investor_research) || []
  def investor_identity(call_id), do: field(call_id, :investor_identity) || %{}
  def retrieval_context(call_id), do: field(call_id, :retrieval_context) || []
  def pre_call_stage(call_id), do: field(call_id, :pre_call_stage) || :choosing

  def recent_text(call_id, limit \\ 8) do
    call_id
    |> transcript()
    |> Transcript.recent_text(limit)
  end

  def best_candidate(call_id) do
    call_id
    |> response_queue()
    |> Negotiator.ResponseQueue.best()
  end

  # -- moss session: local per-call transcript indexing and retrieval --

  def index_transcript(call_id, turn) when is_binary(call_id) and is_map(turn) do
    MossSession.index_transcript(call_id, turn)
  end

  def moss_search(call_id, query, opts \\ []) when is_binary(call_id) and is_binary(query) do
    MossSession.search(call_id, query, opts)
  end

  def async(call_id, fun) when is_binary(call_id) and is_function(fun, 0) do
    Task.Supervisor.start_child(@supervisor, fn ->
      fun.()
    end)
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:named_table, :public, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
