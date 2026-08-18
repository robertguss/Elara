defmodule Mix.Tasks.Harness.Worker do
  use Mix.Task

  @shortdoc "Run an authenticated remote tool worker"

  @default_capabilities ["filesystem:read", "filesystem:write", "shell"]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [port: :integer, cwd: :string, capability: :keep, public: :boolean]
      )

    with [workspace_id] <- args,
         [] <- invalid,
         token when is_binary(token) and token != "" <- System.get_env("HARNESS_WORKER_TOKEN") do
      capabilities = Keyword.get_values(opts, :capability)
      capabilities = if capabilities == [], do: @default_capabilities, else: capabilities
      cwd = Path.expand(Keyword.get(opts, :cwd, File.cwd!()))
      ip = if Keyword.get(opts, :public, false), do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

      {:ok, worker} =
        Harness.Worker.Server.start_link(
          port: Keyword.get(opts, :port, 4_049),
          ip: ip,
          token: token,
          capabilities: capabilities,
          workspaces: %{workspace_id => cwd}
        )

      Mix.shell().info(
        "Harness worker listening on #{format_ip(ip)}:#{Harness.Worker.Server.port(worker)} " <>
          "for workspace #{workspace_id} with #{Enum.join(capabilities, ", ")}"
      )

      Process.sleep(:infinity)
    else
      _ ->
        Mix.raise(
          "usage: HARNESS_WORKER_TOKEN=... mix harness.worker WORKSPACE_ID " <>
            "[--port PORT] [--cwd PATH] [--capability CAP] [--public]"
        )
    end
  end

  defp format_ip({a, b, c, d}), do: Enum.join([a, b, c, d], ".")
end
