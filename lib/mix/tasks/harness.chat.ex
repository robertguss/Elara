defmodule Mix.Tasks.Harness.Chat do
  @shortdoc "Chat with the coding agent"
  @moduledoc """
  Chat with the harness coding agent.

      mix harness.chat
      mix harness.chat "what files are in this repo?"

  Requires `mix harness.login` or `HARNESS_API_KEY` / `XAI_API_KEY`.
  """
  @requirements ["app.start"]
  use Mix.Task

  @impl true
  def run(argv), do: Harness.Chat.main(argv)
end
