defmodule Mix.Tasks.Harness.Server do
  use Mix.Task

  @shortdoc "Run the local detachable-session server"
  @moduledoc """
  Run the local detachable-session server.

  Start with `elixir --erl "+Bc" -S mix harness.server` if you want Ctrl-C
  to terminate the VM instead of opening the Erlang BREAK menu.
  """

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
        Harness.CLI.Signal.await_shutdown()

      {:error, reason} ->
        Mix.raise("could not start Harness server: #{inspect(reason)}")
    end
  end
end
