defmodule Negotiator.ConversationContext do
  @moduledoc """
  builds json-safe context for voice agents.
  """

  alias Negotiator.{Memory, ResponseQueue, Transcript}

  @default_transcript_limit 12
  @negotiation_roles [:founder, :investor, :negotiation_agent]

  @doc """
  returns the current conversation context for one live call.
  """
  def for_call(call_id, opts \\ []) when is_binary(call_id) do
    transcript_limit = Keyword.get(opts, :transcript_limit, @default_transcript_limit)

    memory = Memory.context(call_id) || %{call_id: call_id}
    transcript = Map.get(memory, :transcript, [])
    response_queue = Map.get(memory, :response_queue, [])
    investor_identity = Map.get(memory, :investor_identity, %{})

    %{
      call_id: call_id,
      mode: Map.get(memory, :mode),
      recent_transcript_text: Transcript.recent_text(transcript, transcript_limit),
      recent_transcript: recent_transcript(transcript, transcript_limit),
      latest_by_role: latest_by_role(transcript),
      investor_identity: clean_value(investor_identity),
      candidates: Map.get(memory, :candidates, []),
      best_candidate: ResponseQueue.best(response_queue)
    }
  end

  @doc """
  returns a role-specific context view for an agent.
  """
  def for_agent(call_id, agent, opts \\ [])

  def for_agent(call_id, :negotiation_agent, opts) when is_binary(call_id) do
    call_id
    |> for_call(opts)
    |> restrict_to_roles(@negotiation_roles)
    |> Map.drop([:candidates, :best_candidate])
  end

  def for_agent(call_id, _agent, opts) when is_binary(call_id) do
    for_call(call_id, opts)
  end

  defp recent_transcript(transcript, limit) do
    transcript
    |> Enum.take(-limit)
    |> Enum.map(&clean_turn/1)
  end

  defp latest_by_role(transcript) do
    transcript
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn turn, acc ->
      role = Map.get(turn, :role)

      if is_nil(role) or Map.has_key?(acc, role) do
        acc
      else
        Map.put(acc, role, clean_turn(turn))
      end
    end)
  end

  defp clean_turn(turn) do
    %{
      role: Map.get(turn, :role),
      room: Map.get(turn, :room, :unknown),
      text: Map.get(turn, :text, ""),
      occurred_at: iso8601(Map.get(turn, :occurred_at))
    }
  end

  defp restrict_to_roles(context, roles) do
    recent_transcript = Enum.filter(context.recent_transcript, &(&1.role in roles))

    context
    |> Map.put(:recent_transcript, recent_transcript)
    |> Map.put(:recent_transcript_text, turns_text(recent_transcript))
    |> Map.update!(:latest_by_role, &Map.take(&1, roles))
  end

  defp turns_text(turns) do
    Enum.map_join(turns, "\n", fn turn ->
      "#{turn.role}: #{turn.text}"
    end)
  end

  defp clean_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp clean_value(%{} = map) do
    Map.new(map, fn {key, value} -> {key, clean_value(value)} end)
  end

  defp clean_value(values) when is_list(values), do: Enum.map(values, &clean_value/1)
  defp clean_value(value), do: value

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value), do: value
end
