defmodule Mix.Tasks.Compile.ExecStub do
  @moduledoc false
  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    cargo =
      System.find_executable("cargo") ||
        Mix.raise("""
        cannot build native/exec-stub because cargo is not available.
        Install Rust and Cargo, then ensure cargo is on PATH.
        """)

    root = __DIR__
    crate = Path.join(root, "native/exec-stub")
    target = Path.join(Mix.Project.build_path(), "exec-stub-target")
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
      Mix.raise("failed to build native/exec-stub with cargo (exit #{status})")
    end

    profile = if release?, do: "release", else: "debug"
    source = Path.join([target, profile, "exec-stub"])
    destination = Path.join(Mix.Project.app_path(), "priv/native/exec-stub")
    File.mkdir_p!(Path.dirname(destination))
    copy_if_changed!(source, destination)
    File.chmod!(destination, 0o755)
    {:ok, []}
  end

  defp copy_if_changed!(source, destination) do
    source_contents = File.read!(source)

    unless File.read(destination) == {:ok, source_contents} do
      case File.cp(source, destination) do
        :ok ->
          :ok

        {:error, :etxtbsy} ->
          Mix.raise("""
          cannot replace the running native exec stub at #{destination}.
          Stop long-lived Elara processes using this build, or give concurrent
          processes separate MIX_BUILD_PATH values, then compile again.
          """)

        {:error, reason} ->
          message = reason |> :file.format_error() |> List.to_string()
          Mix.raise("cannot install native exec stub: #{message}")
      end
    end
  end
end

defmodule Elara.MixProject do
  use Mix.Project

  def project do
    [
      app: :elara,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: [:exec_stub] ++ Mix.compilers(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Elara.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:exqlite, "~> 0.40.0"},
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.11"}
    ]
  end
end
