defmodule Negotiator.Research.Disabled do
  @moduledoc """
  explicit no-op research provider when web search is not configured.
  """

  @behaviour Negotiator.Research

  require Logger

  @impl true
  def search(query, _opts \\ []) do
    Logger.info("web research disabled; configure WEB_SEARCH_API_KEY",
      query_chars: String.length(to_string(query || ""))
    )

    {:ok, []}
  end
end
