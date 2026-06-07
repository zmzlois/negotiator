defmodule Negotiator.LLM.Models do
  @moduledoc """
  central model names for text llm calls.
  """

  alias Negotiator.Env

  @openai_chat "gpt-4o-mini"
  @openai_identity "gpt-4o-mini"

  @doc """
  returns the openai chat model used for agent text generation.
  """
  def openai_chat, do: Env.get("OPENAI_CHAT_MODEL", @openai_chat)

  @doc """
  returns the openai model used for investor identity extraction.
  """
  def openai_identity, do: Env.get("OPENAI_IDENTITY_MODEL", @openai_identity)
end
