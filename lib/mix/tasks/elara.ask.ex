defmodule Mix.Tasks.Elara.Ask do
  @shortdoc "Ask the coding agent a question about this repo"
  @moduledoc """
  Ask the coding agent.

      mix elara.ask "what files are in this repo?"

  Requires `mix elara.login` or `ELARA_API_KEY` / `XAI_API_KEY`.
  """
  @requirements ["app.start"]
  use Mix.Task

  @impl true
  def run(argv), do: Elara.CLI.main(argv)
end
