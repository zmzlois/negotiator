defmodule NegotiatorWeb.Router do
  @moduledoc """
  http and websocket boundary for local telnyx voice calls.
  """

  use Plug.Router

  alias Negotiator.CallSupervisor
  alias Negotiator.Telephony.{MediaSocket, TelnyxWebhook}
  alias Negotiator.Telephony.Telnyx.{CacheBodyReader, SignaturePlug}
  alias NegotiatorWeb.{CallSocket, CallView, DevCallControls, DevTelnyxWebhook, Json}

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    body_reader: {CacheBodyReader, :read_body, []}
  )

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{ok: true}))
  end

  get "/runtime" do
    Json.send(conn, 200, Negotiator.RuntimeStatus.snapshot())
  end

  get "/calls" do
    calls =
      CallSupervisor.active_calls()
      |> Enum.map(&CallView.summary/1)

    Json.send(conn, 200, %{calls: calls})
  end

  get "/records" do
    records = CallView.call_records()
    Json.send(conn, 200, %{records: records})
  end

  get "/calls/:call_control_id" do
    case CallSupervisor.call_snapshot(call_control_id) do
      {:ok, snapshot} ->
        Json.send(conn, 200, snapshot)

      {:error, :not_found} ->
        Json.send(conn, 404, %{error: :call_not_found, call_id: call_control_id})
    end
  end

  post "/dev/calls/:call_control_id/say" do
    handle_dev_control(conn, fn ->
      DevCallControls.say(call_control_id, conn.body_params)
    end)
  end

  post "/dev/calls/:call_control_id/partial" do
    handle_dev_control(conn, fn ->
      DevCallControls.partial(call_control_id, conn.body_params)
    end)
  end

  post "/dev/calls/:call_control_id/transcription" do
    handle_dev_control(conn, fn ->
      DevCallControls.transcription(call_control_id, conn.body_params)
    end)
  end

  post "/dev/calls/:call_control_id/media-frame" do
    handle_dev_control(conn, fn ->
      DevCallControls.media_frame(call_control_id, conn.body_params)
    end)
  end

  post "/dev/calls/:call_control_id/dtmf" do
    handle_dev_control(conn, fn ->
      DevCallControls.dtmf(call_control_id, conn.body_params)
    end)
  end

  post "/dev/calls/:call_control_id/resume" do
    handle_dev_control(conn, fn ->
      DevCallControls.resume(call_control_id)
    end)
  end

  post "/dev/calls/:call_control_id/media/:participant/connect" do
    handle_dev_control(conn, fn ->
      DevCallControls.connect_media(call_control_id, participant)
    end)
  end

  post "/dev/telnyx/webhook" do
    handle_dev_control(conn, fn ->
      DevTelnyxWebhook.handle(conn.body_params)
    end)
  end

  get "/dev/calls/:call_control_id/media/:participant" do
    handle_dev_control(conn, fn ->
      DevCallControls.media_events(call_control_id, participant)
    end)
  end

  delete "/dev/calls/:call_control_id/media/:participant" do
    handle_dev_control(conn, fn ->
      DevCallControls.clear_media(call_control_id, participant)
    end)
  end

  post "/telnyx/webhook" do
    handle_telnyx_webhook(conn)
  end

  post "/webhooks/telnyx" do
    handle_telnyx_webhook(conn)
  end

  get "/ws/calls" do
    conn
    |> WebSockAdapter.upgrade(CallSocket, %{}, timeout: 60_000)
    |> halt()
  end

  get "/telnyx/media-streaming" do
    conn
    |> WebSockAdapter.upgrade(MediaSocket, %{}, timeout: 60_000)
    |> halt()
  end

  get "/media/:call_control_id" do
    conn
    |> WebSockAdapter.upgrade(MediaSocket, %{call_control_id: call_control_id}, timeout: 60_000)
    |> halt()
  end

  get "/media/:call_control_id/:participant" do
    conn
    |> WebSockAdapter.upgrade(
      MediaSocket,
      %{call_control_id: call_control_id, participant: participant},
      timeout: 60_000
    )
    |> halt()
  end

  defp handle_telnyx_webhook(conn) do
    case SignaturePlug.verify_conn(conn) do
      :ok ->
        TelnyxWebhook.handle(conn.body_params)
        send_resp(conn, 200, "")

      {:error, _reason} ->
        send_resp(conn, 401, "")
    end
  end

  defp handle_dev_control(conn, action) do
    if DevCallControls.enabled?() do
      case action.() do
        {:ok, snapshot} -> Json.send(conn, 200, snapshot)
        {:error, :not_found} -> Json.send(conn, 404, %{error: :not_found})
        {:error, reason} -> Json.send(conn, 400, %{error: reason})
      end
    else
      Json.send(conn, 403, %{
        error: :dev_controls_disabled,
        required_env: "NEGOTIATOR_DEV_CONTROLS_ENABLED=1"
      })
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
