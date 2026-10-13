defmodule Mix.Tasks.Elara.Env do
  @shortdoc "List command environment names, never their values"
  @moduledoc "Shows forwarded and withheld command environment names; it does not run a command."
  @requirements ["app.config"]
  use Mix.Task

  @impl true
  def run([]) do
    case Elara.Exec.Environment.names() do
      {:ok, names} ->
        for {label, entries} <- [{"Forwarded", names.forwarded}, {"Withheld", names.withheld}] do
          Mix.shell().info(label <> " (names only):")
          Enum.each(entries, &Mix.shell().info("  " <> inspect(&1)))
        end

      {:error, message} ->
        Mix.raise(message)
    end
  end

  def run(_), do: Mix.raise("usage: mix elara.env")
end
