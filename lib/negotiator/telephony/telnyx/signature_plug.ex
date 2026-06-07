defmodule Negotiator.Telephony.Telnyx.SignaturePlug do
  @moduledoc """
  validates signed telnyx webhook requests.
  """

  @behaviour Plug

  import Plug.Conn

  alias Negotiator.Telephony.Telnyx.Signature

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case verify_conn(conn) do
      :ok ->
        conn

      {:error, reason} ->
        Logger.warning("telnyx signature rejected: #{inspect(reason)}")
        conn |> send_resp(401, "") |> halt()
    end
  end

  def verify_conn(conn) do
    with [signature_b64] <- get_req_header(conn, "telnyx-signature-ed25519"),
         [timestamp] <- get_req_header(conn, "telnyx-timestamp"),
         body when is_binary(body) <- raw_body(conn),
         public_key when is_binary(public_key) <- public_key() do
      Signature.verify(signature_b64, timestamp, body, public_key)
    else
      _other -> {:error, :missing_signature_input}
    end
  end

  defp public_key do
    Application.get_env(:negotiator, :telnyx_public_key) ||
      System.get_env("TELNYX_PUBLIC_KEY")
  end

  defp raw_body(conn) do
    case conn.assigns[:raw_body] do
      [_ | _] = chunks -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      _other -> nil
    end
  end
end
