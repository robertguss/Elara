defmodule Mix.Tasks.Elara.Tui do
  use Mix.Task

  @shortdoc "Run the Rust protocol-v2 terminal client"
  @requirements ["app.start"]

  @impl true
  def run(argv) do
    binary = binary!()

    port =
      Port.open({:spawn_executable, String.to_charlist(binary)}, [
        :binary,
        :exit_status,
        :nouse_stdio,
        args: Enum.map(argv, &String.to_charlist/1)
      ])

    await_exit(port)
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
