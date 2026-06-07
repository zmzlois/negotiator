defmodule Negotiator.Orchestration do
  @moduledoc """
  maps call modes to rooms, participant state, and phone audio routing.
  """

  @rooms [:main, :briefing, :small_talk]
  @roles [:founder, :investor, :negotiation_agent, :small_talk_agent]

  def for_mode(mode) do
    %{
      mode: mode,
      audio_route: audio_route_for_mode(mode),
      active_rooms: active_rooms(mode),
      rooms: rooms(mode),
      participants: participants(mode)
    }
  end

  def room_for_role(%{participants: participants}, role) when role in @roles do
    participants
    |> Map.fetch!(role)
    |> Map.fetch!(:room)
  end

  def audio_route(%{audio_route: route}), do: route

  defp audio_route_for_mode(:practice), do: :direct
  defp audio_route_for_mode(:ended), do: :muted

  defp audio_route_for_mode(mode) when mode in [:briefing, :agent_takeover],
    do: :cloned_small_talk_voice

  defp audio_route_for_mode(_mode), do: :direct

  defp active_rooms(:normal), do: [:main]
  defp active_rooms(:briefing), do: [:briefing, :small_talk]
  defp active_rooms(:agent_takeover), do: [:small_talk]
  defp active_rooms(:practice), do: [:main]
  defp active_rooms(:returning), do: [:main]
  defp active_rooms(:ended), do: []

  defp rooms(mode) do
    participants = participants(mode)

    Map.new(@rooms, fn room ->
      roles =
        participants
        |> Enum.filter(fn {_role, state} -> state.room == room end)
        |> Enum.map(fn {role, _state} -> role end)

      {room, %{participants: roles, active?: room in active_rooms(mode)}}
    end)
  end

  defp participants(:normal) do
    %{
      founder: participant(:main, phone_muted?: false, hears: [:investor]),
      investor: participant(:main, phone_muted?: false, hears: [:founder]),
      negotiation_agent: participant(:briefing, active?: false, private?: true),
      small_talk_agent: participant(:small_talk, active?: false, phone_muted?: true)
    }
  end

  defp participants(:briefing) do
    %{
      founder:
        participant(:briefing,
          phone_muted?: true,
          private?: true,
          hears: [:negotiation_agent]
        ),
      investor: participant(:small_talk, phone_muted?: false, hears: [:small_talk_agent]),
      negotiation_agent: participant(:briefing, private?: true, hears: [:founder, :investor]),
      small_talk_agent: participant(:small_talk, active?: true, hears: [:investor])
    }
  end

  defp participants(:agent_takeover) do
    %{
      founder:
        participant(:small_talk,
          phone_muted?: true,
          side_listening?: true,
          hears: [:investor, :small_talk_agent]
        ),
      investor: participant(:small_talk, phone_muted?: false, hears: [:small_talk_agent]),
      negotiation_agent: participant(:briefing, active?: false, private?: true),
      small_talk_agent: participant(:small_talk, active?: true, hears: [:investor])
    }
  end

  defp participants(:practice) do
    %{
      founder: participant(:main, phone_muted?: false, hears: [:investor]),
      investor: participant(:main, phone_muted?: false, hears: [:founder]),
      negotiation_agent: participant(:briefing, active?: false, private?: true),
      small_talk_agent: participant(:small_talk, active?: false, phone_muted?: true)
    }
  end

  defp participants(:returning) do
    %{
      founder: participant(:main, phone_muted?: false, hears: [:investor]),
      investor: participant(:main, phone_muted?: false, hears: [:founder]),
      negotiation_agent: participant(:briefing, active?: false, private?: true),
      small_talk_agent: participant(:small_talk, active?: false, phone_muted?: true)
    }
  end

  defp participants(:ended) do
    Map.new(@roles, fn role ->
      {role, participant(:main, active?: false, phone_muted?: true)}
    end)
  end

  defp participant(room, opts) do
    %{
      room: room,
      active?: Keyword.get(opts, :active?, true),
      phone_muted?: Keyword.get(opts, :phone_muted?, false),
      private?: Keyword.get(opts, :private?, false),
      side_listening?: Keyword.get(opts, :side_listening?, false),
      hears: Keyword.get(opts, :hears, [])
    }
  end
end
