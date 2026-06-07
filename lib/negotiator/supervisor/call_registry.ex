defmodule Negotiator.CallRegistry do
  @moduledoc """
  registry for active call sessions, keyed by telnyx call_control_id.
  """

  @registry __MODULE__

  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: @registry)

  def via_call_session(call_id), do: {:via, Registry, {@registry, {:call_session, call_id}}}

  def whereis_call_session(call_id) do
    case Registry.lookup(@registry, {:call_session, call_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  lists active call sessions registered by telnyx call_control_id.
  """
  def active_call_sessions do
    @registry
    |> Registry.select([{{{:call_session, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {call_id, pid} -> %{call_id: call_id, pid: pid} end)
    |> Enum.sort_by(& &1.call_id)
  end
end
