defmodule Negotiator.Agents.SmallTalkAgent do
  @moduledoc """
  public voice that keeps the investor conversation warm.
  owns queued continuation selection and public reply input.
  """

  alias Negotiator.{ConversationContext, Memory, Tools}

  @transcript_limit 6

  @doc """
  creates the next line the cloned voice may speak.
  uses pre-ranked candidate if available, otherwise generates via llm.
  """
  def reply(state) do
    case selected_candidate(state) do
      %{text: text} when is_binary(text) and text != "" ->
        text

      _missing ->
        Tools.llm_complete(state.llm, :small_talk_reply, reply_input(state))
    end
  end

  @doc """
  predicts one queued continuation for the public agent.
  """
  def queued_continuation(state, prompt_text) do
    Tools.llm_complete(state.llm, :queued_continuation, continuation_input(state, prompt_text))
  end

  @doc """
  returns the selected queued candidate line, when one exists.
  """
  def selected_candidate(state), do: Memory.best_candidate(state.call_id)

  @doc """
  builds public reply model input from memory and retrieval.
  """
  def reply_input(state) do
    conversation = ConversationContext.for_call(state.call_id, transcript_limit: @transcript_limit)

    %{
      call_id: state.call_id,
      mode: state.mode,
      transcript: conversation.recent_transcript_text,
      latest_by_role: conversation.latest_by_role,
      candidates: Memory.candidates(state.call_id),
      context: Memory.retrieval_context(state.call_id)
    }
  end

  @doc """
  builds queued-continuation model input from rolling partial transcript text.
  """
  def continuation_input(state, prompt_text) do
    %{
      call_id: state.call_id,
      mode: state.mode,
      transcript: prompt_text,
      context: Memory.retrieval_context(state.call_id)
    }
  end
end
