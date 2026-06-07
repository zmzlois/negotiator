defmodule NegotiatorWeb.Json do
  @moduledoc """
  encodes runtime snapshots as http json.
  """

  @doc """
  sends a json response after normalizing elixir runtime values.
  """
  def send(conn, status, payload) do
    Plug.Conn.send_resp(conn, status, Jason.encode!(normalize(payload)))
  end

  @doc """
  normalizes and encodes a payload as a json string.
  """
  def encode(payload) do
    payload |> normalize() |> Jason.encode!()
  end

  @doc """
  converts internal values into json-safe terms.
  """
  def normalize(value) when is_boolean(value) or is_nil(value), do: value
  def normalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def normalize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def normalize(pid) when is_pid(pid), do: inspect(pid)
  def normalize(ref) when is_reference(ref), do: inspect(ref)
  def normalize(value) when is_atom(value), do: Atom.to_string(value)

  def normalize(%_{} = value) do
    value
    |> Map.from_struct()
    |> normalize()
  end

  def normalize(value) when is_map(value) do
    Map.new(value, fn {key, value} ->
      {normalize_key(key), normalize(value)}
    end)
  end

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)
end
