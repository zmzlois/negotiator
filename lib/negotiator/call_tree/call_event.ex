defmodule Negotiator.CallEvent do
  @moduledoc """
  normalized events that enter a call session from telephony and provider adapters.
  """

  defstruct source: nil, type: nil, payload: %{}

  @doc """
  records a provider event without implying a state transition.
  """
  def provider(source, type, payload \\ %{}) when is_atom(source) and is_atom(type) do
    %__MODULE__{source: source, type: type, payload: Map.new(payload)}
  end

  @doc """
  registers the process that can receive outbound phone audio.
  """
  def register_media_socket(socket_pid, metadata \\ %{}) when is_pid(socket_pid) do
    %__MODULE__{
      source: :media_socket,
      type: :register,
      payload:
        metadata
        |> Map.new()
        |> Map.put(:socket_pid, socket_pid)
    }
  end

  @doc """
  carries one inbound telnyx media frame.
  """
  def media_frame(bytes, metadata \\ %{}) when is_binary(bytes) do
    %__MODULE__{
      source: :media_socket,
      type: :media_frame,
      payload: %{bytes: bytes, metadata: Map.new(metadata)}
    }
  end

  def media_mark(name, metadata \\ %{}) do
    %__MODULE__{
      source: :media_socket,
      type: :media_mark,
      payload:
        metadata
        |> Map.new()
        |> Map.put(:name, to_string(name))
    }
  end

  @doc """
  carries a telnyx in-call transcription result.
  """
  def transcription(text, final?, metadata \\ %{}) when is_binary(text) do
    %__MODULE__{
      source: :telnyx_webhook,
      type: :transcription,
      payload:
        metadata
        |> Map.new()
        |> Map.put(:text, text)
        |> Map.put(:final?, !!final?)
    }
  end

  @doc """
  carries one founder dtmf digit.
  """
  def dtmf(digit) do
    %__MODULE__{source: :telephony, type: :dtmf, payload: %{digit: to_string(digit)}}
  end

  @doc """
  marks the call ended.
  """
  def end_call(reason) do
    %__MODULE__{source: :call, type: :end_call, payload: %{reason: reason}}
  end
end
