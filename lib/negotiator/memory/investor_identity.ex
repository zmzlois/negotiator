defmodule Negotiator.InvestorIdentity do
  @moduledoc """
  normalizes the investor identity attached to call transcripts.
  """

  alias Negotiator.LLM

  @empty %{name: nil, number: nil, firm: nil}
  @fields [:name, :number, :firm]

  @doc """
  returns the empty investor identity shape.
  """
  def empty, do: @empty

  @doc """
  builds the default identity from explicit call-session options.
  """
  def from_opts(opts) when is_list(opts) do
    opts
    |> Keyword.get(:investor_identity, %{})
    |> normalize()
    |> merge(%{
      name: Keyword.get(opts, :investor_name),
      number: Keyword.get(opts, :investor_number),
      firm: Keyword.get(opts, :investor_firm)
    })
  end

  @doc """
  extracts explicit investor identity fields from a provider payload.
  """
  def from_payload(payload) when is_map(payload) do
    direct =
      %{
        name: value(payload, ["investor_name", :investor_name]),
        number: value(payload, ["investor_number", :investor_number]),
        firm: value(payload, ["investor_firm", :investor_firm])
      }
      |> normalize()

    nested =
      payload
      |> nested_identity()
      |> normalize()

    merge(direct, nested)
  end

  def from_payload(_payload), do: @empty

  @doc """
  returns a trimmed map using the canonical identity keys.
  """
  def normalize(identity) when is_map(identity) do
    %{
      name: first_present(identity, [:name, "name", :investor_name, "investor_name"]),
      number:
        first_present(identity, [
          :number,
          "number",
          :phone_number,
          "phone_number",
          :investor_number,
          "investor_number"
        ]),
      firm: first_present(identity, [:firm, "firm", :investor_firm, "investor_firm"])
    }
  end

  def normalize(_identity), do: @empty

  @doc """
  merges two identities, preferring non-empty values from the second map.
  """
  def merge(left, right) do
    left = normalize(left)
    right = normalize(right)

    Map.new(@fields, fn field ->
      {field, Map.get(right, field) || Map.get(left, field)}
    end)
  end

  @doc """
  extracts investor identity fields from transcript text through llm structured response.
  """
  def from_transcript(transcript_text) when is_binary(transcript_text) do
    if extractor = Application.get_env(:negotiator, :investor_identity_extractor) do
      transcript_text
      |> extractor.extract()
      |> normalize()
    else
      openai_identity_from_transcript(transcript_text)
    end
  end

  def from_transcript(_transcript_text), do: @empty

  @doc """
  backwards-compatible wrapper for older call sites.
  """
  def from_text(text), do: from_transcript(text)

  defp openai_identity_from_transcript(transcript_text) do
    case LLM.OpenAI.structured_response(:investor_identity, transcript_text) do
      {:ok, identity} -> normalize(identity)
      {:error, _reason} -> @empty
    end
  end

  @doc """
  returns true when all required call-bridge identity fields are present.
  """
  def complete?(identity) do
    identity = normalize(identity)
    Enum.all?(@fields, &(Map.get(identity, &1) not in [nil, ""]))
  end

  @doc """
  returns missing required identity fields.
  """
  def missing_fields(identity) do
    identity = normalize(identity)

    Enum.filter(@fields, fn field ->
      Map.get(identity, field) in [nil, ""]
    end)
  end

  @doc """
  returns true when none of the identity fields are available.
  """
  def empty?(identity) do
    identity
    |> normalize()
    |> Map.values()
    |> Enum.all?(&is_nil/1)
  end

  @doc """
  returns a string-keyed version safe for json metadata.
  """
  def metadata(identity) do
    identity = normalize(identity)

    %{
      "investor_name" => identity.name,
      "investor_number" => identity.number,
      "investor_firm" => identity.firm
    }
  end

  defp nested_identity(payload) do
    value(payload, [
      "investor",
      :investor,
      "investor_identity",
      :investor_identity
    ]) || %{}
  end

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key -> clean(Map.get(map, key)) end)
  end

  defp value(map, keys), do: Enum.find_value(keys, fn key -> Map.get(map, key) end)

  defp clean(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp clean(value) when is_integer(value), do: Integer.to_string(value)
  defp clean(value) when is_float(value), do: Float.to_string(value)
  defp clean(_value), do: nil
end
