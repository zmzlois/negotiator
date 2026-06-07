defmodule Negotiator.Agents.NegotiationAgent do
  @moduledoc """
  private coach that helps the founder recover during a live call.
  owns fresh transcript selection, moss context, and private advice input.
  """

  alias Negotiator.{ConversationContext, Memory, Tools}

  @doc """
  creates private coaching. reads from memory for fresh conversation state.
  """
  def advise(state) do
    Tools.llm_complete(state.llm, :negotiation_advice, advice_input(state))
  end

  @doc """
  builds private advice model input from memory and retrieval.
  """
  @transcript_limit 6

  def advice_input(state) do
    conversation = ConversationContext.for_agent(state.call_id, :negotiation_agent,
      transcript_limit: @transcript_limit
    )

    %{
      call_id: state.call_id,
      mode: state.mode,
      latest_text: get_in(conversation, [:latest_by_role, :investor, :text]) || "",
      transcript: conversation.recent_transcript_text,
      latest_by_role: conversation.latest_by_role,
      context: Memory.retrieval_context(state.call_id)
    }
  end
end
