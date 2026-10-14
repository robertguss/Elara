defmodule Mix.Tasks.Elara.Recordings do
  @shortdoc "Show retained storage or explicitly preview/apply recording pruning"
  @moduledoc "Reports retained storage; pruning is preview-only unless --apply is supplied."
  @requirements ["app.start"]
  use Mix.Task

  @impl true
  def run([]) do
    {:ok, sizes} = Elara.Recordings.diagnostics()
    Mix.shell().info("Recordings: #{sizes.recordings_bytes} bytes")
    Mix.shell().info("Retained output: #{sizes.retained_output_bytes} bytes (logical size)")
  end

  def run(["prune" | args]) do
    case OptionParser.parse(args, strict: [older_than: :integer, apply: :boolean]) do
      {opts, [], []} ->
        case Keyword.fetch(opts, :older_than) do
          {:ok, days} when days >= 0 ->
            {:ok, results} = Elara.Recordings.prune(days, apply: Keyword.get(opts, :apply, false))

            Enum.each(results, fn result ->
              Mix.shell().info("#{inspect(result.status)} #{result.path}")
            end)

            if not Keyword.get(opts, :apply, false),
              do: Mix.shell().info("Preview only; add --apply to delete. Live sessions are kept.")

          _ ->
            usage()
        end

      _ ->
        usage()
    end
  end

  def run(_), do: usage()

  defp usage,
    do: Mix.raise("usage: mix elara.recordings [prune --older-than DAYS [--apply]]")
end
