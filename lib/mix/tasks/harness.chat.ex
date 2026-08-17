defmodule Mix.Tasks.Harness.Chat do
  @shortdoc "Chat with the coding agent"
  @moduledoc """
  Chat with the harness coding agent.

      mix harness.chat
      mix harness.chat --continue
      mix harness.chat "what files are in this repo?"

  Requires `mix harness.login` or `HARNESS_API_KEY` / `XAI_API_KEY`.
  """
  @requirements ["app.start"]
  use Mix.Task

  @switches [continue: :boolean]

  @impl true
  def run(argv) do
    case parse_args(argv) do
      {:ok, remaining, opts} ->
        Harness.Chat.main(remaining, opts)

      {:error, message} ->
        Mix.shell().error(message)
        exit({:shutdown, 1})
    end
  end

  @doc false
  @spec parse_args([String.t()]) ::
          {:ok, [String.t()], keyword()} | {:error, String.t()}
  def parse_args(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, remaining, []} ->
        {:ok, remaining, continue: Keyword.get(opts, :continue, false)}

      {_opts, _remaining, [{flag, _value} | _]} ->
        {:error, "unknown option: #{flag}"}
    end
  end
end
