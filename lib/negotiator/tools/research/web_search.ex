defmodule Negotiator.Research.WebSearch do
  @moduledoc """
  web search via brave search api for live investor research.
  """

  @behaviour Negotiator.Research

  alias Negotiator.{Env, Tools}

  require Logger

  @impl true
  def search(query, opts \\ []) do
    count = Keyword.get(opts, :count, 5)
    api_key = Env.fetch!("WEB_SEARCH_API_KEY")

    Logger.info("web search started", query: query, count: count)
    started_at = System.monotonic_time(:millisecond)

    case Tools.http_get(
           url: "https://api.search.brave.com/res/v1/web/search",
           params: [q: query, count: count],
           headers: [
             {"X-Subscription-Token", api_key},
             {"Accept", "application/json"}
           ],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        results = parse_results(body)
        duration_ms = System.monotonic_time(:millisecond) - started_at

        Logger.info("web search completed",
          query: query,
          results: length(results),
          duration_ms: duration_ms
        )

        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("web search http error", query: query, status: status)
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.warning("web search failed", query: query, reason: inspect(reason))
        {:error, reason}
    end
  end

  defp parse_results(%{"web" => %{"results" => results}}) do
    Enum.map(results, fn r ->
      %{
        title: r["title"] || "",
        url: r["url"] || "",
        snippet: r["description"] || ""
      }
    end)
  end

  defp parse_results(_body), do: []
end
