defmodule Mix.Tasks.Elara.Trust do
  use Mix.Task

  @shortdoc "Review and approve repository plugin source before execution"
  @requirements ["app.config"]

  @impl true
  def run(argv) do
    cwd =
      case argv do
        [] -> File.cwd!()
        [workspace] -> Path.expand(workspace)
        _ -> Mix.raise("usage: mix elara.trust [WORKSPACE]")
      end

    case Elara.Plugin.Trust.snapshot(Elara.Plugin.discover(cwd)) do
      {:ok, []} ->
        Mix.shell().info("No repository plugins found.")

      {:ok, entries} ->
        Mix.shell().info(
          "These plugins can run code with your full OS-user authority, including during compilation:"
        )

        Enum.each(entries, &Mix.shell().info("#{inspect(&1.path)} SHA256 #{&1.sha256}"))

        answer = IO.gets("Approve these exact plugin files? [y/N] ")

        if is_binary(answer) and String.downcase(String.trim(answer)) in ["y", "yes"] do
          case Elara.Plugin.Trust.approve(entries) do
            :ok -> Mix.shell().info("Approved. Changed or new plugin files need approval again.")
            {:error, reason} -> Mix.raise("could not save plugin approval: #{inspect(reason)}")
          end
        else
          Mix.shell().info("No plugin approval saved.")
        end

      {:error, reason} ->
        Mix.raise("could not read repository plugins: #{inspect(reason)}")
    end
  end
end
