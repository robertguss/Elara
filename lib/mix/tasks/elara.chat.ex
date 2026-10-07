defmodule Mix.Tasks.Elara.Chat do
  @shortdoc "Chat with the coding agent"
  @moduledoc """
  Chat with the coding agent.

      mix elara.chat
      mix elara.chat --continue
      mix elara.chat --name "display name"
      mix elara.chat "what files are in this repo?"

  Requires a Grok/OpenAI login or `ELARA_API_KEY` / `XAI_API_KEY`.
  """
  @requirements ["app.start"]
  use Mix.Task

  @switches [continue: :boolean, name: :string, cwd: :string]

  @impl true
  def run(argv) do
    case parse_args(argv) do
      {:ok, remaining, opts} ->
        Elara.Chat.main(remaining, opts)

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
        with {:ok, workspace} <- Elara.CLI.workspace_options(Keyword.take(opts, [:cwd])) do
          {:ok, remaining,
           [continue: Keyword.get(opts, :continue, false), name: Keyword.get(opts, :name)] ++
             workspace}
        end

      {_opts, _remaining, [{flag, _value} | _]} ->
        {:error, "unknown option: #{flag}"}
    end
  end
end
