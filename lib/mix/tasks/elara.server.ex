defmodule Mix.Tasks.Elara.Server do
  use Mix.Task

  @shortdoc "Run the local detachable-session server"
  @moduledoc """
  Run the local detachable-session server.

  Start with `elixir --erl "+Bc" -S mix elara.server` if you want Ctrl-C
  to terminate the VM instead of opening the Erlang BREAK menu.
  """

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: [port: :integer])

    if args != [] or invalid != [] do
      Mix.raise("usage: mix elara.server [--port PORT]")
    end

    port = Keyword.get(opts, :port, 4_048)

    case Elara.Server.start_link(port: port, name: Elara.Server) do
      {:ok, server} ->
        Mix.shell().info("Elara server listening on 127.0.0.1:#{Elara.Server.port(server)}")
        Elara.CLI.Signal.await_shutdown()

      {:error, reason} ->
        Mix.raise("could not start Elara server: #{Elara.Config.error_message(reason)}")
    end
  end
end
