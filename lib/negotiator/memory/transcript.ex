defmodule Negotiator.Transcript do
  @moduledoc """
  small helpers for transcript entries.
  """

  @roles [:founder, :investor, :negotiation_agent, :small_talk_agent]

  def roles, do: @roles

  @doc """
  normalizes external role names into transcript role atoms.
  """
  def normalize_role(role) when role in @roles, do: role

  def normalize_role(role) when is_binary(role) do
    role
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_existing_atom()
    |> normalize_role()
  rescue
    ArgumentError -> raise ArgumentError, "unknown transcript role: #{inspect(role)}"
  end

  @doc """
  appends one final speech turn to the transcript.
  """
  def append(transcript, role, text) when role in @roles and is_binary(text) do
    append(transcript, role, text, %{})
  end

  def append(_transcript, role, _text) do
    raise ArgumentError, "unknown transcript role: #{inspect(role)}"
  end

  def append(transcript, role, text, metadata) when role in @roles and is_binary(text) do
    clean_text = String.trim(text)

    if clean_text == "" do
      transcript
    else
      transcript ++
        [
          %{
            role: role,
            text: clean_text,
            occurred_at: DateTime.utc_now()
          }
          |> Map.merge(Map.new(metadata))
        ]
    end
  end

  def append(_transcript, role, _text, _metadata) do
    raise ArgumentError, "unknown transcript role: #{inspect(role)}"
  end

  @doc """
  counts simple whitespace-separated words in the full transcript.
  """
  def word_count(transcript) do
    transcript
    |> Enum.map_join(" ", & &1.text)
    |> words()
    |> length()
  end

  @doc """
  returns recent transcript text for retrieval and agent prompts.
  """
  def recent_text(transcript, limit \\ 8) do
    transcript
    |> Enum.take(-limit)
    |> Enum.map_join("\n", fn turn -> "#{turn.role}: #{turn.text}" end)
  end

  defp words(text) do
    Regex.scan(~r/[[:alnum:]'$-]+/u, String.downcase(text))
    |> List.flatten()
  end
end
