defmodule Negotiator.Voice.Ulaw do
  @moduledoc """
  encodes and decodes g.711 u-law bytes for telnyx pcmu streams.
  """

  import Bitwise

  @bias 0x84
  @clip 32635

  decoded_table =
    for byte <- 0..255 do
      inverted = bxor(byte, 0xFF)
      sign = band(inverted, 0x80)
      exponent = band(bsr(inverted, 4), 0x07)
      mantissa = band(inverted, 0x0F)
      sample = bsl(bor(bsl(mantissa, 3), 0x84), exponent) - 0x84

      if sign != 0, do: -sample, else: sample
    end

  @decode_table List.to_tuple(decoded_table)

  @doc """
  decodes one μ-law byte into signed 16-bit pcm.
  """
  def decode_byte(byte) when is_integer(byte) and byte in 0..255, do: elem(@decode_table, byte)

  @doc """
  encodes one signed 16-bit pcm sample into a μ-law byte.
  """
  def encode_sample(sample) when is_integer(sample) do
    sign = if sample < 0, do: 0x80, else: 0x00
    magnitude = min(abs(sample), @clip) + @bias

    exponent = find_exponent(magnitude)
    mantissa = band(bsr(magnitude, exponent + 3), 0x0F)
    bxor(bor(sign, bor(bsl(exponent, 4), mantissa)), 0xFF)
  end

  defp find_exponent(magnitude) do
    Enum.find(7..0//-1, 0, fn exp ->
      band(magnitude, bsl(1, exp + 7)) != 0
    end)
  end

  @doc """
  decodes u-law bytes into little-endian signed 16-bit pcm.
  """
  def decode_to_pcm16(bytes) when is_binary(bytes) do
    for <<byte <- bytes>>, into: <<>> do
      <<decode_byte(byte)::little-signed-16>>
    end
  end

  @doc """
  applies a linear volume fade-out to u-law audio bytes.
  ramps from full volume to silence over the entire buffer.
  """
  def fade_out(<<>>), do: <<>>

  def fade_out(bytes) when is_binary(bytes) do
    total = byte_size(bytes)

    bytes
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} ->
      factor = max(0.0, 1.0 - index / total)
      sample = decode_byte(byte)
      faded = round(sample * factor)
      encode_sample(faded)
    end)
    |> :binary.list_to_bin()
  end
end
