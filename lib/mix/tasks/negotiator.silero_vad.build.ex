defmodule Mix.Tasks.Negotiator.SileroVad.Build do
  @moduledoc """
  builds the native silero vad end-of-turn helper.
  """

  use Mix.Task

  @shortdoc "builds the native silero vad end-of-turn helper"

  @impl true
  def run(_args) do
    {output, status} =
      System.cmd("make", ["-C", "native/silero_vad_eot"], stderr_to_stdout: true)

    IO.write(output)

    if status != 0 do
      Mix.raise("native silero vad build failed")
    end
  end
end
