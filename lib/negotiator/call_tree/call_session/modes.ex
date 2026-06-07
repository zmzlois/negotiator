defmodule Negotiator.CallSession.Modes do
  @moduledoc """
  applies call mode transitions and room orchestration.
  """

  alias Negotiator.CallSession.EventLog
  alias Negotiator.Orchestration

  @modes [:normal, :briefing, :agent_takeover, :returning, :ended, :practice]

  @doc """
  changes mode and refreshes the room graph when needed.
  """
  def change(state, mode) when mode in @modes do
    if state.mode == mode do
      state
    else
      old_mode = state.mode
      orchestration = Orchestration.for_mode(mode)

      state
      |> Map.put(:mode, mode)
      |> Map.put(:orchestration, orchestration)
      |> EventLog.append(:mode_changed, %{
        from: old_mode,
        to: mode,
        active_rooms: orchestration.active_rooms
      })
    end
  end

  @doc """
  rejoins the founder to the main room and mutes the small-talk agent.
  """
  def return_founder(state, source) do
    state
    |> change(:returning)
    |> EventLog.append(:small_talk_agent_muted, %{reason: :founder_returning, source: source})
    |> EventLog.append(:founder_rejoined, %{source: source})
  end
end
