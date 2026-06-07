defmodule NegotiatorWeb.CallView do
  @moduledoc """
  shapes call session data for http and websocket responses.
  """

  @doc """
  returns a compact call summary for the active calls list.
  matches the desktop BackendCall type contract.
  """
  @snapshot_timeout_ms 2_000

  def summary(%{call_id: call_id, pid: pid}) do
    snapshot = GenServer.call(pid, :state, @snapshot_timeout_ms)
    identity = snapshot.investor_identity || %{}

    %{
      call_id: call_id,
      pid: pid,
      mode: snapshot.mode,
      audio_route: snapshot.audio_route,
      response_lifecycle: snapshot.response_lifecycle,
      transcript: format_transcript(snapshot.transcript),
      candidates: snapshot.candidates,
      briefing: snapshot.briefing,
      prediction_checkpoint: snapshot.prediction_checkpoint,
      investor_name: identity[:name] || identity["name"],
      investor_firm: identity[:firm] || identity["firm"],
      media_socket_participants: snapshot.media_socket_participants,
      latest_audio_participant: snapshot.latest_audio_participant,
      latest_turn_decision: snapshot.latest_turn_decision,
      last_events: format_events(snapshot.last_events),
      pre_call_stage: snapshot.pre_call_stage,
      founder_phone: snapshot[:founder_phone]
    }
  catch
    :exit, _ ->
      %{call_id: call_id, pid: pid, mode: :unknown, transcript: [], last_events: []}
  end

  defp format_transcript(transcript) when is_list(transcript) do
    Enum.map(transcript, fn turn ->
      %{
        role: turn.role,
        text: turn.text,
        room: Map.get(turn, :room, :main)
      }
    end)
  end

  defp format_transcript(_), do: []

  defp format_events(events) when is_list(events) do
    Enum.map(events, fn
      %{type: type, sequence: seq} ->
        %{type: type, sequence: seq}

      %{type: type} ->
        %{type: type}

      other ->
        %{type: inspect(other)}
    end)
  end

  defp format_events(_), do: []

  @doc """
  returns completed call records grouped by call_id from sqlite.
  """
  def call_records do
    import Ecto.Query

    Negotiator.TranscriptTurn
    |> order_by([t], desc: t.occurred_at)
    |> Negotiator.Repo.all()
    |> Enum.group_by(& &1.call_id)
    |> Enum.map(fn {call_id, turns} ->
      sorted = Enum.sort_by(turns, & &1.sequence)
      first = List.first(sorted)
      last = List.last(sorted)

      %{
        id: call_id,
        investorName: first.investor_name || "unknown",
        investorFirm: first.investor_firm || "unknown",
        dateLabel: format_date(first.occurred_at),
        duration: format_duration(first.occurred_at, last.occurred_at),
        status: infer_status(sorted),
        summary: build_summary(sorted),
        lastNote: "",
        keyMoments: [],
        transcript:
          Enum.map(sorted, fn t ->
            %{role: t.role, text: t.text, room: t.room || "main"}
          end),
        events: []
      }
    end)
    |> Enum.sort_by(& &1.dateLabel, :desc)
  rescue
    _ -> []
  end

  defp format_date(nil), do: "unknown"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y %H:%M")
  end

  defp format_date(_), do: "unknown"

  defp format_duration(nil, _), do: "unknown"
  defp format_duration(_, nil), do: "unknown"

  defp format_duration(%DateTime{} = start_dt, %DateTime{} = end_dt) do
    seconds = DateTime.diff(end_dt, start_dt, :second) |> abs()

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  defp format_duration(_, _), do: "unknown"

  defp infer_status(turns) do
    roles = MapSet.new(turns, & &1.role)

    cond do
      MapSet.member?(roles, "small_talk_agent") -> "agent takeover"
      MapSet.member?(roles, "negotiation_agent") -> "briefing used"
      true -> "completed"
    end
  end

  defp build_summary(turns) do
    founder_turns = Enum.filter(turns, &(&1.role == "founder"))

    case founder_turns do
      [] -> "no founder speech recorded"
      [first | _] -> String.slice(first.text || "", 0, 120)
    end
  end
end
