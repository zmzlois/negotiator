defmodule Negotiator.Agents.SimulatedInvestor do
  @moduledoc """
  llm-driven investor stand-in for solo development.
  owns investor prompt input and research query construction.
  """

  alias Negotiator.{ConversationContext, InvestorIdentity, Memory, Tools}

  @doc """
  creates the next investor turn, enriched with any available research.
  reads from memory for fresh conversation state.
  """
  def next_turn(state) do
    transcript = Memory.transcript(state.call_id)

    cond do
      transcript == [] ->
        opening_prompt()

      founder_turns(transcript) == [] ->
        opening_followup_prompt()

      intake_required?(state) ->
        intake_prompt(state)

      true ->
        Tools.llm_complete(state.llm, :investor_turn, turn_input(state))
    end
  end

  @doc """
  builds investor-turn model input from memory.
  """
  @transcript_limit 6

  def turn_input(state) do
    conversation = ConversationContext.for_call(state.call_id, transcript_limit: @transcript_limit)

    %{
      call_id: state.call_id,
      mode: state.mode,
      transcript: conversation.recent_transcript_text,
      latest_by_role: conversation.latest_by_role,
      investor_identity: conversation.investor_identity,
      research: Memory.investor_research(state.call_id),
      context: Memory.retrieval_context(state.call_id),
      pitch_phase: pitch_phase_guidance(conversation.recent_transcript_text)
    }
  end

  @pitch_phases [
    {"opening", "what are you building and why does it need to exist now?"},
    {"market", "what's the TAM? who's buying today? why this wedge?"},
    {"traction", "users, revenue, growth rate, retention — show me the numbers"},
    {"unit economics", "CAC, LTV, payback period, margins, burn rate"},
    {"competition", "why can't an incumbent build this? what's the moat?"},
    {"team", "why you? what's the unfair advantage? who's missing?"},
    {"deal terms", "valuation, dilution, who else is in, use of funds"},
    {"stress test", "what if this doesn't work? what keeps you up at night?"}
  ]

  defp pitch_phase_guidance(transcript_text) do
    text = String.downcase(transcript_text || "")

    {done, remaining} =
      Enum.split_with(@pitch_phases, fn {phase, _} ->
        String.contains?(text, phase)
      end)

    done_text = if done == [], do: "none yet", else: Enum.map_join(done, ", ", &elem(&1, 0))

    next_text =
      case remaining do
        [{phase, question} | _] -> "next: #{phase} — #{question}"
        [] -> "all phases covered — go deeper on weak answers or do a final stress test"
      end

    "\n\npitch phase status:\ncovered: #{done_text}\n#{next_text}"
  end

  @doc """
  returns the first spoken line for the founder-facing call intake.
  """
  def opening_prompt do
    "yo so this is your negotiation helper, are you here for pitch practice or do you want to call an investor"
  end

  defp opening_followup_prompt do
    "still with me? say pitch practice if you want to rehearse, or tell me the investor name, firm, and phone number when you want me to call"
  end

  defp founder_turns(transcript) do
    Enum.filter(transcript, &(&1.role == :founder))
  end

  defp intake_required?(state) do
    state.pre_call_stage == :collecting_investor or
      Memory.pre_call_stage(state.call_id) == :collecting_investor or
      not InvestorIdentity.empty?(Memory.investor_identity(state.call_id))
  end

  defp intake_prompt(state) do
    identity = Memory.investor_identity(state.call_id)

    if InvestorIdentity.complete?(identity) do
      "got it. i have #{identity.name} at #{identity.firm}, #{identity.number}. i'll prep context before bridging the investor call."
    else
      missing = identity |> InvestorIdentity.missing_fields() |> Enum.map_join(", ", &to_string/1)

      "before i bridge the investor call, i need #{missing}."
    end
  end

  @doc """
  generates web search queries based on the conversation so far.
  """
  def research_queries(state) do
    Tools.llm_complete(state.llm, :investor_research_queries, research_query_input(state))
  end

  @doc """
  builds investor research-query model input from memory.
  """
  def research_query_input(state) do
    conversation = ConversationContext.for_call(state.call_id)

    %{
      transcript: conversation.recent_transcript_text,
      conversation: conversation
    }
  end
end
