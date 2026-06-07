defmodule Negotiator do
  @moduledoc """
  public entry points for supervised voice call sessions.
  """

  @doc """
  starts a call session under the application supervisor.
  """
  def start_call(opts \\ []) do
    Negotiator.CallSupervisor.start_call(opts)
  end

  @doc """
  returns a read-only snapshot of a call session.
  """
  def state(call_session) do
    Negotiator.CallSession.state(call_session)
  end
end
