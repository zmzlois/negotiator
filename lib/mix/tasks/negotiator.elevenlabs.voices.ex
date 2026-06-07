defmodule Mix.Tasks.Negotiator.Elevenlabs.Voices do
  @moduledoc """
  lists elevenlabs voices available to the configured api key.
  """

  use Mix.Task

  @shortdoc "lists elevenlabs voice ids for ELEVENLABS_VOICE_ID"

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          env_file: :keep,
          search: :string,
          category: :string,
          voice_type: :string,
          limit: :integer
        ]
      )

    opts
    |> Keyword.get_values(:env_file)
    |> load_dotenv()

    Mix.Task.run("app.start")

    case Negotiator.LLM.Speech.ElevenLabsVoices.list(
           search: opts[:search],
           category: opts[:category],
           voice_type: opts[:voice_type],
           page_size: opts[:limit] || 20
         ) do
      {:ok, voices} ->
        print_voices(voices)

      {:error, reason} ->
        Mix.raise("could not list elevenlabs voices: #{inspect(reason)}")
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

  defp print_voices([]) do
    IO.puts("no elevenlabs voices returned")
  end

  defp print_voices(voices) do
    IO.puts("elevenlabs voices\n")

    Enum.each(voices, fn voice ->
      IO.puts("#{voice.voice_id}\t#{voice.name}\t#{voice.category || "unknown"}")
    end)

    IO.puts("\nset ELEVENLABS_VOICE_ID to the voice_id you want the negotiator to use")
  end
end
