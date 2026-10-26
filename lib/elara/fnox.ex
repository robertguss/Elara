defmodule Elara.Fnox do
  @moduledoc "Approved stock-fnox defaults, not a sandbox; secret plans never enter session state."

  alias Elara.{Exec, Output, Tool}
  alias Elara.Exec.Environment

  @filenames ~w(fnox.toml .fnox.toml .config/fnox.toml fnox.local.toml .fnox.local.toml .config/fnox.local.toml)
  @flags ~w(--config fnox.toml --profile default --no-daemon --non-interactive --if-missing error --no-color)
  @changed "fnox config changed; /approve again"

  defp present?(cwd) do
    Enum.any?(@filenames, &File.exists?(Path.join(cwd, &1))) or
      (Path.dirname(cwd) != cwd and present?(Path.dirname(cwd)))
  end

  def review(cwd) do
    if present?(cwd) do
      with executable when is_binary(executable) <- System.find_executable("fnox"),
           {:ok, output} <- private_run(executable, ["config-files"], cwd, 5_000, 1_048_576),
           paths = String.split(output, "\n", trim: true),
           true <- paths != [] and length(paths) <= 256,
           {:ok, files} <- hash_files(paths) do
        {:ok, %{"cwd" => cwd, "files" => files}}
      else
        _ ->
          {:error, "fnox config discovery failed; install fnox 1.39+ and check its configuration"}
      end
    else
      {:ok, nil}
    end
  end

  def run(%Tool.Ctx{} = ctx, argv) do
    case with_environment(ctx, &Output.capture(ctx, {:command, argv, &1})) do
      {:error, {:not_started, reason}} -> {:error, reason}
      result -> result
    end
  end

  def exec(%Tool.Ctx{} = ctx, argv, opts) do
    with_environment(ctx, &Exec.run(argv, Keyword.merge(opts, &1)))
  end

  defp with_environment(ctx, operation) do
    with {:ok, config} <- review(ctx.cwd),
         true <- config == ctx.fnox_config do
      if config do
        resolve_and_run(ctx, operation, config)
      else
        operation.([])
      end
    else
      _ -> {:error, {:not_started, @changed}}
    end
  end

  defp resolve_and_run(ctx, operation, config) do
    executable = System.find_executable("fnox")

    result =
      private_run(
        executable,
        ["env", "--json", "--for", "exec"],
        ctx.cwd,
        min(ctx.timeout_ms || 30_000, 30_000),
        8_388_608
      )

    # Even an unsuccessful resolution can have invoked provider code. Never
    # launch the model command after a visible configuration change.
    if review(ctx.cwd) == {:ok, config} do
      with {:ok, json} <- result,
           {:ok, document} <- JSON.decode(json) do
        owner = self()

        {:ok, cleanup} =
          Task.Supervisor.start_child(Elara.TaskSup, fn ->
            monitor = Process.monitor(owner)
            cleanup_files(owner, monitor, [])
          end)

        try do
          case plan(document, cleanup) do
            {:ok, plan, files} ->
              try do
                operation.(trusted_environment: plan)
              after
                Enum.each(files, &File.rm/1)
              end

            _ ->
              resolution_error()
          end
        after
          send(cleanup, :finished)
        end
      else
        _ -> resolution_error()
      end
    else
      {:error, {:not_started, @changed}}
    end
  end

  defp cleanup_files(owner, monitor, paths) do
    receive do
      {:file, path} -> cleanup_files(owner, monitor, [path | paths])
      :finished -> Enum.each(paths, &File.rm/1)
      {:DOWN, ^monitor, :process, ^owner, _} -> Enum.each(paths, &File.rm/1)
    end
  end

  defp resolution_error do
    {:error,
     {:not_started,
      "fnox resolution failed; unlock/authenticate its providers outside Elara and retry (non-interactive, 30s limit)"}}
  end

  defp private_run(executable, args, cwd, timeout, limit) do
    case Exec.run([executable | @flags ++ args],
           cwd: cwd,
           timeout_ms: timeout,
           max_bytes: limit,
           trusted_environment: Environment.fnox_resolver()
         ) do
      {:ok, %Exec.Result{termination: :exited, code: 0, output: output}} -> {:ok, output}
      _ -> {:error, :resolution_failed}
    end
  end

  defp hash_files(paths) do
    Enum.reduce_while(Enum.sort(Enum.uniq(paths)), {:ok, []}, fn path, {:ok, files} ->
      with true <- Path.type(path) == :absolute,
           {:ok, %{type: :regular, size: size}} when size <= 8_388_608 <- File.stat(path),
           {:ok, bytes} <- File.read(path) do
        file = %{
          "path" => path,
          "digest" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
        }

        {:cont, {:ok, files ++ [file]}}
      else
        _ -> {:halt, {:error, :unreadable_config}}
      end
    end)
  end

  defp plan(
         %{
           "schema" => 1,
           "scope" => "exec",
           "profile" => ["default"],
           "set" => set,
           "remove" => remove,
           "files" => files,
           "missing" => []
         },
         cleanup
       )
       when is_map(set) and is_map(files) and is_list(remove) do
    with true <- Enum.all?(remove, &is_binary/1),
         true <- Enum.all?(set, &valid_secret?/1) and Enum.all?(files, &valid_secret?/1),
         {:ok, environment} <- Environment.command(%{}),
         {:ok, paths} <- secret_files(files, cleanup) do
      values = environment |> Map.drop(remove) |> Map.merge(set) |> Map.merge(Map.new(paths))

      redactions =
        Map.merge(set, files)
        |> Enum.reject(fn {_name, value} -> value == "" end)
        |> Enum.sort_by(fn {name, value} -> {-byte_size(value), name} end)
        |> Enum.map(fn {name, value} -> [value, "[fnox:#{name}]"] end)

      {:ok, %Environment{values: values, redactions: redactions}, Enum.map(paths, &elem(&1, 1))}
    else
      _ -> {:error, :invalid_plan}
    end
  end

  defp plan(_, _), do: {:error, :invalid_plan}

  defp valid_secret?({name, value}) do
    is_binary(name) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name) and
      not Environment.credential?(name) and is_binary(value) and
      not String.contains?(value, <<0>>) and byte_size(value) <= 65_536
  end

  defp secret_files(files, cleanup) do
    {:ok, sessions_root} = Elara.Session.Store.root()
    root = Path.join(sessions_root, "_fnox")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    Enum.reduce_while(files, {:ok, []}, fn {name, bytes}, {:ok, paths} ->
      path = Path.join(root, Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false))
      send(cleanup, {:file, path})

      case File.open(path, [:write, :exclusive, :binary]) do
        {:ok, file} ->
          result = with :ok <- File.chmod(path, 0o600), do: IO.binwrite(file, bytes)
          File.close(file)

          if result == :ok do
            {:cont, {:ok, [{name, path} | paths]}}
          else
            Enum.each([path | Enum.map(paths, &elem(&1, 1))], &File.rm/1)
            {:halt, {:error, :file_secret_failed}}
          end

        _ ->
          Enum.each(paths, &File.rm(elem(&1, 1)))
          {:halt, {:error, :file_secret_failed}}
      end
    end)
  end
end
