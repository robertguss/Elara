defmodule Mix.Tasks.Harness.Ask do
  @shortdoc "Ask the coding agent a question about this repo"
  @moduledoc """
  Ask the harness coding agent.

      mix harness.ask "what files are in this repo?"

  Requires `mix harness.login` or `HARNESS_API_KEY` / `XAI_API_KEY`.
  """
  @requirements ["app.start"]
  use Mix.Task

  @impl true
  def run(argv), do: Harness.CLI.main(argv)
end
