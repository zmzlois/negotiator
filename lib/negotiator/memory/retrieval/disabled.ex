defmodule Negotiator.Retrieval.Disabled do
  @moduledoc """
  explicit no-op retrieval provider when moss is not configured.
  """

  @behaviour Negotiator.Retrieval

  require Logger

  @impl true
  def search(query, _opts \\ []) do
    Logger.info("retrieval disabled; configure moss",
      query_chars: String.length(to_string(query || ""))
    )

    []
  end
end
