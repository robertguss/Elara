defmodule Mix.Tasks.Harness.Server do
  use Mix.Task

  @shortdoc "Run the local detachable-session server"

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: [port: :integer])

    if args != [] or invalid != [] do
      Mix.raise("usage: mix harness.server [--port PORT]")
    end

    port = Keyword.get(opts, :port, 4_048)

    case Harness.Server.start_link(port: port, name: Harness.Server) do
      {:ok, server} ->
        Mix.shell().info("Harness server listening on 127.0.0.1:#{Harness.Server.port(server)}")
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("could not start Harness server: #{inspect(reason)}")
    end
  end
end
