defmodule Mix.Tasks.Elara.Tui do
  use Mix.Task

  @shortdoc "Run the Rust protocol-v2 terminal client"
  @moduledoc """
  Run the Rust protocol-v2 terminal client.

  New and saved-session targets start an embedded server when the selected port
  is free. Start `mix elara.server` separately when sessions must outlive this
  command. Pass options before `-- SESSION` when the session ID starts with `-`.
  """
  @requirements ["app.start"]

  @default_port 4_048
  @switches [
    port: :integer,
    observe: :boolean,
    headless: :boolean,
    event_dump: :boolean,
    dump_events: :boolean,
    ask: :string,
    interrupt_after_ms: :integer,
    timeout_ms: :integer,
    width: :integer,
    height: :integer,
    appearance: :boolean,
    layout: :string,
    theme: :string,
    preview_reasoning: :boolean,
    help: :boolean
  ]

  @impl true
  def run(argv) do
    binary = binary!()
    maybe_start_embedded_server(argv)

    port =
      Port.open({:spawn_executable, String.to_charlist(binary)}, [
        :binary,
        :exit_status,
        :nouse_stdio,
        args: Enum.map(argv, &String.to_charlist/1)
      ])

    await_exit(port)
  end

  defp maybe_start_embedded_server(argv) do
    case OptionParser.parse(argv, strict: @switches, aliases: [o: :observe, h: :help]) do
      {opts, command, []} when command != [] ->
        port = Keyword.get(opts, :port, environment_port())

        if is_integer(port) and port in 1..65_535 do
          start_embedded_server(port)
        end

      _other_command_or_invalid_arguments ->
        :ok
    end
  end

  defp start_embedded_server(port) do
    case Elara.Server.start(port: port, name: Elara.Server, lifetime: :embedded) do
      {:ok, _server} ->
        :ok

      {:error, :eaddrinuse} ->
        :ok

      {:error, {:already_started, server}} ->
        if Elara.Server.port(server) == port do
          :ok
        else
          Mix.raise(
            "Elara.Server is already running on port #{Elara.Server.port(server)}, " <>
              "but the TUI selected port #{port}"
          )
        end

      {:error, reason} ->
        Mix.raise("could not start embedded Elara server: #{Elara.Config.error_message(reason)}")
    end
  end

  defp environment_port do
    case Integer.parse(System.get_env("ELARA_SERVER_PORT", "")) do
      {port, ""} when port in 1..65_535 -> port
      _invalid_or_missing -> @default_port
    end
  end

  @doc false
  @spec binary!() :: String.t()
  def binary! do
    destination = Application.app_dir(:elara, "priv/native/elara-tui")
    digest = source_digest()

    unless File.regular?(destination) and File.read(destination <> ".sha256") == {:ok, digest} do
      build!(destination, digest)
    end

    destination
  end

  defp build!(destination, digest) do
    cargo =
      System.find_executable("cargo") ||
        Mix.raise("""
        cannot build native/elara-tui because cargo is not available.
        Install Rust and Cargo, then ensure cargo is on PATH.
        """)

    crate = Path.expand("../../../native/elara-tui", __DIR__)
    target = Path.join(Mix.Project.build_path(), "elara-tui-target")
    release? = Mix.env() == :prod
    args = ["build", "--locked"] ++ if(release?, do: ["--release"], else: [])

    {output, status} =
      System.cmd(cargo, args,
        cd: crate,
        env: [{"CARGO_TARGET_DIR", target}],
        stderr_to_stdout: true
      )

    IO.write(output)

    if status != 0 do
      Mix.raise("failed to build native/elara-tui with cargo (exit #{status})")
    end

    profile = if release?, do: "release", else: "debug"
    source = Path.join([target, profile, "elara-tui"])
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(source, destination)
    File.chmod!(destination, 0o755)
    File.write!(destination <> ".sha256", digest)
  end

  defp source_digest do
    crate = Path.expand("../../../native/elara-tui", __DIR__)

    content =
      ["Cargo.toml", "Cargo.lock", "src/**/*"]
      |> Enum.flat_map(&Path.wildcard(Path.join(crate, &1)))
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()
      |> Enum.map(fn path -> [Path.relative_to(path, crate), 0, File.read!(path), 0] end)

    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end

  defp await_exit(port) do
    receive do
      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        exit({:shutdown, status})

      {^port, {:data, _data}} ->
        await_exit(port)
    end
  end
end
