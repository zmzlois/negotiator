defmodule Negotiator.Telephony do
  @moduledoc """
  telephony boundary for live phone calls.
  """

  @callback required_env() :: [String.t()]
  @callback setup_plan() :: [String.t()]
  @callback answer(String.t()) :: :ok | {:ok, term()} | {:error, term()}
  @callback start_streaming(String.t(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  @callback start_transcription(String.t(), keyword()) ::
              :ok | {:ok, term()} | {:error, term()} | :disabled
  @callback dial_investor(String.t(), map()) :: :ok | {:ok, term()} | {:error, term()}
  @callback bridge(String.t(), String.t()) :: :ok | {:ok, term()} | {:error, term()}
end
