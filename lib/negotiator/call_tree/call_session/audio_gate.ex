defmodule Negotiator.CallSession.AudioGate do
  @moduledoc """
  answers whether a provider is allowed to own the phone audio path.
  """

  alias Negotiator.Orchestration
  alias Negotiator.Voice.PhoneAudio

  def route(state), do: Orchestration.audio_route(state.orchestration)

  def voice_output(state, output, role \\ :small_talk_agent) do
    recipients = voice_recipients(state, role)

    cond do
      route(state) == :muted ->
        {:muted, :call_ended}

      not PhoneAudio.telnyx_ready?(output) ->
        {:muted, :not_telnyx_ready}

      recipients == [] ->
        {:muted, :no_audible_media_socket}

      true ->
        {:send, recipients}
    end
  end

  def all_recipients(state) do
    state
    |> media_sockets()
    |> Enum.reject(fn {_participant, pid} -> not is_pid(pid) end)
  end

  defp voice_recipients(state, role) do
    state
    |> media_sockets()
    |> Enum.filter(fn {participant, pid} ->
      is_pid(pid) and phone_participant_can_hear?(state, participant, role)
    end)
  end

  defp phone_participant_can_hear?(state, participant, role) do
    state.orchestration
    |> Map.fetch!(:participants)
    |> Map.fetch!(participant)
    |> Map.fetch!(:hears)
    |> Enum.member?(role)
  end

  defp media_sockets(%{media_sockets: sockets}) when map_size(sockets) > 0 do
    Map.to_list(sockets)
  end

  defp media_sockets(%{media_socket_pid: pid, phone_participant: participant}) when is_pid(pid) do
    [{participant, pid}]
  end

  defp media_sockets(_state), do: []
end
