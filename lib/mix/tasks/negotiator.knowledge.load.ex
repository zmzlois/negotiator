defmodule Mix.Tasks.Negotiator.Knowledge.Load do
  @moduledoc """
  converts unsiloed book exports into moss documents.
  """

  use Mix.Task

  alias Moss.Client
  alias Negotiator.{Env, Knowledge.Unsiloed}

  @shortdoc "loads unsiloed negotiation books into moss"
  @default_books "priv/knowledge/books"
  @default_model "moss-minilm"

  @impl true
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          books: :string,
          index: :string,
          env_file: :keep,
          push: :boolean,
          create: :boolean,
          model: :string,
          raw_only: :boolean,
          cards_only: :boolean,
          limit: :integer,
          min_words: :integer,
          min_page: :integer
        ]
      )

    reject_invalid!(invalid)
    validate_mode!(opts)

    opts
    |> Keyword.get_values(:env_file)
    |> load_dotenv()

    docs =
      opts
      |> books_dir()
      |> Unsiloed.load_directory!(converter_opts(opts))
      |> limit_docs(opts[:limit])

    if opts[:push] do
      push_docs!(docs, opts)
    else
      print_dry_run(docs, opts)
    end
  end

  defp reject_invalid!([]), do: :ok

  defp reject_invalid!(invalid) do
    invalid =
      Enum.map_join(invalid, ", ", fn
        {name, nil} -> name
        {name, value} -> "#{name}=#{value}"
      end)

    Mix.raise("unknown options: #{invalid}")
  end

  defp validate_mode!(opts) do
    if Keyword.get(opts, :raw_only, false) and Keyword.get(opts, :cards_only, false) do
      Mix.raise("choose --raw-only or --cards-only, not both")
    end
  end

  defp load_dotenv([]), do: Env.load_dotenv()
  defp load_dotenv(paths), do: Env.load_dotenv(paths)

  defp books_dir(opts), do: Keyword.get(opts, :books, @default_books)

  defp converter_opts(opts) do
    [
      include_raw?: not Keyword.get(opts, :cards_only, false),
      include_cards?: not Keyword.get(opts, :raw_only, false),
      min_words: Keyword.get(opts, :min_words, 40),
      min_page: Keyword.get(opts, :min_page, 8)
    ]
  end

  defp limit_docs(docs, nil), do: docs
  defp limit_docs(docs, limit), do: Enum.take(docs, limit)

  defp print_dry_run(docs, opts) do
    IO.puts("knowledge load dry run")
    IO.puts("books: #{books_dir(opts)}")
    IO.puts("docs: #{length(docs)}")
    IO.puts("")

    docs
    |> Unsiloed.summarize()
    |> Enum.each(fn row ->
      IO.puts("#{row.book}\t#{row.kind}\t#{row.count}")
    end)

    case docs do
      [doc | _rest] ->
        IO.puts("\nfirst doc")
        IO.puts("id: #{doc.id}")
        IO.puts("kind: #{doc.metadata["kind"]}")
        IO.puts("book: #{doc.metadata["book"]}")
        IO.puts("pages: #{doc.metadata["page_start"]}-#{doc.metadata["page_end"]}")
        IO.puts("text: #{String.slice(doc.text, 0, 260)}")

      [] ->
        IO.puts("no documents generated")
    end

    IO.puts("\npass --push to write these documents to moss")
  end

  defp push_docs!([], _opts), do: Mix.raise("no documents generated")

  defp push_docs!(docs, opts) do
    index_name = Keyword.get(opts, :index) || Env.fetch!("MOSS_INDEX_NAME")
    model = Keyword.get(opts, :model, @default_model)

    {:ok, client} =
      Client.new(
        Env.fetch!("MOSS_PROJECT_ID"),
        moss_project_key(),
        client_opts()
      )

    result =
      case Client.get_index(client, index_name) do
        {:ok, _index} ->
          Client.add_docs(client, index_name, docs, upsert: true)

        {:error, reason} ->
          if Keyword.get(opts, :create, false) do
            Client.create_index(client, index_name, docs, model)
          else
            {:error,
             "moss index #{index_name} was not found or could not be read: #{inspect(reason)}. pass --create to create it."}
          end
      end

    case result do
      {:ok, mutation} ->
        IO.puts("moss knowledge load queued")
        IO.puts("index: #{index_name}")
        IO.puts("docs: #{length(docs)}")
        IO.puts("job: #{mutation.job_id}")

      {:error, reason} ->
        Mix.raise("could not load moss documents: #{inspect(reason)}")
    end
  end

  defp moss_project_key do
    case Env.get("MOSS_PROJECT_KEY") || Env.get("MOSS_API_KEY") do
      value when is_binary(value) and value != "" -> value
      _missing -> Env.fetch!("MOSS_PROJECT_KEY")
    end
  end

  defp client_opts do
    case Env.get("MOSS_BASE_URL") do
      value when is_binary(value) and value != "" -> [base_url: value]
      _missing -> []
    end
  end
end
