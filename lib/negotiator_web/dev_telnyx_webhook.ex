defmodule NegotiatorWeb.DevTelnyxWebhook do
  @moduledoc """
  local telnyx webhook harness backed by the dev telephony adapter.
  """

  alias Negotiator.CallSupervisor
  alias Negotiator.Telephony.{DevTelnyx, TelnyxWebhook}

  @doc """
  handles a telnyx-style webhook without calling telnyx.
  """
  def handle(params) do
    call_id = call_id(params)
    TelnyxWebhook.handle(params, telephony: DevTelnyx)

    {:ok,
     %{
       call_id: call_id,
       commands: call_id && DevTelnyx.commands(call_id),
       call: call_id && call_snapshot(call_id)
     }}
  end

  defp call_id(%{"data" => %{"payload" => %{"call_control_id" => call_id}}}), do: call_id
  defp call_id(_params), do: nil

  defp call_snapshot(nil), do: nil

  defp call_snapshot(call_id) do
    case CallSupervisor.call_snapshot(call_id) do
      {:ok, snapshot} -> snapshot
      {:error, :not_found} -> nil
    end
  end
end
