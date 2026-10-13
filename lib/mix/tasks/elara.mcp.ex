defmodule Mix.Tasks.Elara.Mcp do
  use Mix.Task
  @shortdoc "Approve exact MCP config and catalog, with explicit read-only tool marks"
  @requirements ["app.start"]

  alias Elara.MCP.{Config, Trust}

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: [cwd: :string, read_only: :string])

    unless invalid == [] and match?([command, _] when command in ["trust", "info"], args),
      do:
        Mix.raise("usage: mix elara.mcp trust|info NAME [--cwd DIR] [--read-only tool_a,tool_b]")

    [command, name] = args
    cwd = Path.expand(Keyword.get(opts, :cwd, File.cwd!()))

    case command do
      "info" ->
        case Elara.MCP.diagnostics(cwd, name) do
          {:ok, diagnostics} -> Mix.shell().info(JSON.encode!(diagnostics))
          error -> Mix.raise("could not inspect MCP connection: #{inspect(error)}")
        end

      "trust" ->
        trust(cwd, name, opts)
    end
  end

  defp trust(cwd, name, opts) do
    marks =
      Keyword.get(opts, :read_only, "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    with {:ok, config} <- Config.read(cwd, name) do
      Mix.shell().info("MCP #{inspect(name)} from #{config.path}; config SHA256 #{config.sha256}")

      Mix.shell().info(
        JSON.encode!(config |> Map.from_struct() |> Map.update!(:transport, &Atom.to_string/1))
      )

      Mix.shell().info(
        "Connecting starts trusted code or contacts this endpoint with its configured credentials. This is not a sandbox."
      )

      if confirm("Approve this exact config and connect for catalog review?") do
        with :ok <- Trust.approve_config(config),
             {:ok, %{config: connected, tools: tools, diagnostics: diagnostics}} <-
               Elara.MCP.discover(cwd, name),
             true <- connected.sha256 == config.sha256,
             true <- Enum.all?(marks, fn mark -> Enum.any?(tools, &(&1["name"] == mark)) end) do
          Mix.shell().info(
            "Connection diagnostics (not authority): " <> JSON.encode!(diagnostics)
          )

          Mix.shell().info(JSON.encode!(tools))
          Mix.shell().info("Read-only tools: #{inspect(marks)}; every other tool is mutating.")
          Mix.shell().info("Catalog + marks SHA256 #{Trust.digest(tools, marks)}")

          if confirm("Approve this exact catalog and these read-only marks?") do
            case Trust.approve_catalog(config, tools, marks) do
              :ok ->
                Mix.shell().info("Approved. Config or catalog changes require approval again.")

              error ->
                Mix.raise("could not save MCP approval: #{inspect(error)}")
            end
          else
            Mix.shell().info(
              "No new catalog approval saved. Existing approval, if any, is unchanged."
            )
          end
        else
          false ->
            Mix.raise(
              "config changed or an unknown read-only tool was named; no catalog approved"
            )

          error ->
            Mix.raise("could not review MCP catalog: #{inspect(error)}")
        end
      else
        Mix.shell().info("No new MCP approval saved.")
      end
    else
      error -> Mix.raise("could not read MCP config: #{inspect(error)}")
    end
  end

  defp confirm(message) do
    answer = IO.gets(message <> " [y/N] ")
    is_binary(answer) and String.downcase(String.trim(answer)) in ["y", "yes"]
  end
end
