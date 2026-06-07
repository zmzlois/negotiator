defmodule Negotiator.ResponseLifecycle do
  @moduledoc """
  tracks the current agent response lifecycle for one call.
  """

  @terminal_statuses [:idle, :done, :failed, :interrupted, :muted]

  @doc """
  returns the initial response lifecycle state.
  """
  def initial do
    transition(%{}, :idle)
  end

  @doc """
  records a response lifecycle transition.
  """
  def transition(lifecycle, status, metadata \\ %{}) when is_atom(status) do
    previous = Map.new(lifecycle || %{})

    %{
      status: status,
      response_id: Map.get(metadata, :response_id, previous[:response_id]),
      role: Map.get(metadata, :role, previous[:role]),
      route: Map.get(metadata, :route, previous[:route]),
      provider: Map.get(metadata, :provider, previous[:provider]),
      text: Map.get(metadata, :text, previous[:text]),
      playback_mark: Map.get(metadata, :playback_mark, previous[:playback_mark]),
      reason: Map.get(metadata, :reason),
      sent_to_media_socket?: Map.get(metadata, :sent_to_media_socket?),
      updated_at: DateTime.utc_now()
    }
    |> clear_response_id_for_terminal_status()
  end

  defp clear_response_id_for_terminal_status(%{status: status} = lifecycle)
       when status in @terminal_statuses do
    %{lifecycle | response_id: nil}
  end

  defp clear_response_id_for_terminal_status(lifecycle), do: lifecycle
end
