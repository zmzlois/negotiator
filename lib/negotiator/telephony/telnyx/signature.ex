defmodule Negotiator.Telephony.Telnyx.Signature do
  @moduledoc """
  verifies telnyx ed25519 webhook signatures.
  """

  @max_skew_seconds 5 * 60

  @type result :: :ok | {:error, :bad_signature | :malformed | :stale_timestamp}

  @spec verify(String.t(), String.t(), binary(), String.t()) :: result()
  def verify(signature_b64, timestamp, body, public_key_b64)
      when is_binary(signature_b64) and is_binary(timestamp) and is_binary(body) and
             is_binary(public_key_b64) do
    with :ok <- check_timestamp(timestamp),
         {:ok, signature} <- decode_b64(signature_b64),
         {:ok, public_key} <- decode_b64(public_key_b64),
         message <- "#{timestamp}|#{body}",
         true <- :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519]) do
      :ok
    else
      false -> {:error, :bad_signature}
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, :bad_signature}
  end

  def verify(_signature_b64, _timestamp, _body, _public_key_b64), do: {:error, :malformed}

  defp check_timestamp(timestamp) do
    case Integer.parse(timestamp) do
      {timestamp_seconds, ""} when timestamp_seconds > 0 ->
        now = System.system_time(:second)

        if abs(now - timestamp_seconds) <= @max_skew_seconds do
          :ok
        else
          {:error, :stale_timestamp}
        end

      _other ->
        {:error, :malformed}
    end
  end

  defp decode_b64(value) do
    case Base.decode64(value) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :malformed}
    end
  end
end
