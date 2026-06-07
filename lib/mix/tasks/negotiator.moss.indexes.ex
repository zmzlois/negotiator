defmodule Mix.Tasks.Negotiator.Moss.Indexes do
  @moduledoc """
  lists moss indexes available to the configured project.
  """

  use Mix.Task

  @shortdoc "lists moss index names for MOSS_INDEX_NAME"

  @impl true
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [env_file: :keep])

    opts
    |> Keyword.get_values(:env_file)
    |> load_dotenv()

    Mix.Task.run("app.start")

    case Negotiator.Retrieval.Moss.list_indexes() do
      {:ok, indexes} ->
        print_indexes(indexes)

      {:error, reason} ->
        Mix.raise("could not list moss indexes: #{inspect(reason)}")
    end
  end

  defp load_dotenv([]), do: print_dotenv_report(Negotiator.Env.load_dotenv())
  defp load_dotenv(paths), do: print_dotenv_report(Negotiator.Env.load_dotenv(paths))

  defp print_dotenv_report(%{loaded: loaded, aliases: aliases}) do
    Enum.each(loaded, fn %{path: path, keys: keys} ->
      IO.puts("loaded env file #{path} (#{length(keys)} keys)")
    end)

    Enum.each(aliases, fn %{source: source, target: target} ->
      IO.puts("mapped #{source} to #{target}")
    end)

    if loaded != [] or aliases != [], do: IO.puts("")
  end

  defp print_indexes([]) do
    IO.puts("no moss indexes returned")
  end

  defp print_indexes(indexes) do
    IO.puts("moss indexes\n")

    Enum.each(indexes, fn index ->
      IO.puts("#{index.name}\t#{index.status || "unknown"}\t#{index.doc_count || "?"} docs")
    end)

    IO.puts("\nset MOSS_INDEX_NAME to the index name you want the negotiator to search")
  end
end
