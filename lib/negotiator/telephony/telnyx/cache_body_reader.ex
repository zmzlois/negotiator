defmodule Negotiator.Telephony.Telnyx.CacheBodyReader do
  @moduledoc """
  caches the exact raw request body before json parsing.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, cache_body(conn, body)}
      {:more, body, conn} -> {:more, body, cache_body(conn, body)}
      other -> other
    end
  end

  defp cache_body(conn, body) do
    Plug.Conn.assign(conn, :raw_body, [body | conn.assigns[:raw_body] || []])
  end
end
