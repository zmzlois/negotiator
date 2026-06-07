defmodule Negotiator.LLM.ToolExecutor do
  @moduledoc """
  executes tool calls returned by the llm and logs input/result.
  """

  alias Negotiator.{Logging, Memory, Research.WebSearch}

  require Logger

  def execute(call, context \\ %{})

  def execute(%{"function" => %{"name" => "web_search"}} = call, _context) do
    with_args(call, fn %{"query" => query} ->
      run_search(call["id"], query)
    end)
  end

  def execute(%{"function" => %{"name" => "verify_claim"}} = call, _context) do
    with_args(call, fn args ->
      claim = args["claim"] || ""
      ctx = args["context"] || ""
      query = "#{claim} #{ctx} fact check verify"
      run_search(call["id"], query)
    end)
  end

  def execute(%{"function" => %{"name" => "competitor_lookup"}} = call, _context) do
    with_args(call, fn args ->
      company = args["company"] || ""
      aspect = args["aspect"] || "all"

      query =
        case aspect do
          "funding" -> "#{company} funding round valuation investors"
          "product" -> "#{company} product features capabilities"
          "pricing" -> "#{company} pricing plans cost per seat"
          "news" -> "#{company} news announcement 2024 2025"
          _ -> "#{company} startup funding product competitors"
        end

      run_search(call["id"], query)
    end)
  end

  def execute(%{"function" => %{"name" => "calculate_unit_economics"}} = call, _context) do
    with_args(call, fn args ->
      metrics = args["metrics"] || %{}
      content = compute_unit_economics(metrics)
      tool_result(call["id"], content)
    end)
  end

  def execute(%{"function" => %{"name" => "search_recent_news"}} = call, _context) do
    with_args(call, fn args ->
      topic = args["topic"] || ""
      angle = args["angle"] || "all"

      query =
        case angle do
          "acquisitions" -> "#{topic} acquisition acquired merger 2025"
          "launches" -> "#{topic} launch announced new product 2025"
          "regulation" -> "#{topic} regulation policy law compliance 2025"
          "funding" -> "#{topic} funding round raised venture capital 2025"
          "failures" -> "#{topic} shutdown failed closed pivoted"
          _ -> "#{topic} latest news 2025"
        end

      run_search(call["id"], query)
    end)
  end


  def execute(%{"function" => %{"name" => "moss_search"}} = call, context) do
    with_args(call, fn args ->
      query = args["query"] || ""
      role = args["role"]
      call_id = context[:call_id]

      if call_id do
        opts = if role, do: [role: String.to_existing_atom(role)], else: []

        case Memory.moss_search(call_id, query, opts) do
          {:ok, docs} when docs != [] ->
            content = format_moss_results(docs)
            tool_result(call["id"], content)

          {:ok, []} ->
            tool_result(call["id"], "no matching transcript found")

          {:error, reason} ->
            tool_result(call["id"], "transcript search failed: #{inspect(reason)}")
        end
      else
        tool_result(call["id"], "no call context available for transcript search")
      end
    end)
  end

  def execute(%{"function" => %{"name" => name}} = call, _context) do
    Logger.warning("unknown tool call", tool: name)
    tool_result(call["id"], "unknown tool: #{name}")
  end

  # -- shared helpers --

  defp with_args(call, fun) do
    call_id = call["id"]
    args_json = get_in(call, ["function", "arguments"]) || "{}"

    case Jason.decode(args_json) do
      {:ok, args} -> fun.(args)
      {:error, reason} ->
        Logger.warning("tool call bad arguments",
          tool: get_in(call, ["function", "name"]),
          reason: inspect(reason)
        )
        tool_result(call_id, "invalid arguments")
    end
  end

  defp run_search(call_id, query) do
    Logging.provider_call(:started, :tool, :web_search, tool_call_id: call_id, query: query)
    started_at = System.monotonic_time(:millisecond)

    case WebSearch.search(query, count: 3) do
      {:ok, results} ->
        Logging.provider_call(:finished, :tool, :web_search,
          tool_call_id: call_id,
          query: query,
          result_count: length(results),
          duration_ms: System.monotonic_time(:millisecond) - started_at
        )

        tool_result(call_id, format_search_results(results))

      {:error, reason} ->
        Logging.provider_call(:failed, :tool, :web_search,
          tool_call_id: call_id,
          query: query,
          reason: inspect(reason),
          duration_ms: System.monotonic_time(:millisecond) - started_at
        )

        tool_result(call_id, "search failed: #{inspect(reason)}")
    end
  end

  defp tool_result(call_id, content) do
    %{role: "tool", tool_call_id: call_id, content: content}
  end

  defp format_search_results([]), do: "no results found"

  defp format_search_results(results) do
    Enum.map_join(results, "\n\n", fn r ->
      "#{r[:title] || r["title"]}\n#{r[:snippet] || r["snippet"]}\n#{r[:url] || r["url"]}"
    end)
  end

  # -- unit economics calculator --

  defp compute_unit_economics(m) do
    lines = []

    lines = add_if(lines, m["revenue_monthly"] && m["customers"],
      fn -> "arpu: $#{Float.round(m["revenue_monthly"] / m["customers"], 2)}/month" end)

    lines = add_if(lines, m["revenue_monthly"] && m["cac"],
      fn -> "ltv/cac ratio: #{Float.round(m["revenue_monthly"] * 12 / m["cac"], 1)}x (assuming 12-month retention)" end)

    lines = add_if(lines, m["cac"] && m["price_per_unit"],
      fn -> "cac payback: #{Float.round(m["cac"] / m["price_per_unit"], 1)} months" end)

    lines = add_if(lines, m["burn_monthly"] && m["cash_on_hand"],
      fn -> "runway: #{Float.round(m["cash_on_hand"] / m["burn_monthly"], 1)} months" end)

    lines = add_if(lines, m["round_size"] && m["pre_money_valuation"],
      fn ->
        dilution = m["round_size"] / (m["pre_money_valuation"] + m["round_size"]) * 100
        "dilution: #{Float.round(dilution, 1)}% on $#{format_number(m["pre_money_valuation"])} pre"
      end)

    lines = add_if(lines, m["revenue_monthly"] && m["growth_rate_monthly"],
      fn ->
        arr = m["revenue_monthly"] * 12
        arr_12m = m["revenue_monthly"] * :math.pow(1 + m["growth_rate_monthly"] / 100, 12) * 12
        "current arr: $#{format_number(arr)} → projected 12m arr: $#{format_number(arr_12m)} at #{m["growth_rate_monthly"]}% mom"
      end)

    lines = add_if(lines, m["burn_monthly"] && m["revenue_monthly"],
      fn ->
        net = m["revenue_monthly"] - m["burn_monthly"]
        if net < 0, do: "net burn: $#{format_number(abs(net))}/month (not profitable)", else: "net positive: $#{format_number(net)}/month"
      end)

    if lines == [] do
      "not enough numbers provided to calculate. ask the founder for specific metrics."
    else
      Enum.join(lines, "\n")
    end
  end

  defp add_if(lines, condition, fun) do
    if condition, do: lines ++ [fun.()], else: lines
  end

  defp format_number(n) when is_float(n) or is_integer(n) do
    cond do
      n >= 1_000_000 -> "#{Float.round(n / 1_000_000, 1)}M"
      n >= 1_000 -> "#{Float.round(n / 1_000, 0)}K"
      true -> "#{Float.round(n * 1.0, 0)}"
    end
  end

  defp format_number(n), do: to_string(n)

  # -- moss transcript formatting --

  defp format_moss_results(docs) do
    Enum.map_join(docs, "\n\n", fn doc ->
      role = get_in(doc, [:metadata, "role"]) || "unknown"
      room = get_in(doc, [:metadata, "room"]) || ""
      "[#{role}#{if room != "", do: " in #{room}", else: ""}] #{doc[:text]}"
    end)
  end
end
