defmodule Elara.Effect.Ownership do
  @moduledoc "Lifetime admission locks and durable proof of the actual writer/callback owners."

  def canonical_path(path), do: resolve(Path.expand(path), 40)

  defp resolve(_path, 0), do: {:error, :eloop}

  defp resolve(path, remaining) do
    [root | components] = Path.split(path)

    Enum.reduce_while(components, {:ok, root}, fn component, {:ok, parent} ->
      current = Path.join(parent, component)

      case File.read_link(current) do
        {:ok, target} ->
          suffix = Path.relative_to(path, current)
          target = Path.expand(target, Path.dirname(current))
          next = if suffix == ".", do: target, else: Path.join(target, suffix)
          {:halt, resolve(next, remaining - 1)}

        {:error, reason} when reason in [:einval, :enoent] ->
          {:cont, {:ok, current}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def writer do
    encode(%{"format" => 1, "vm" => vm(), "writer" => encode(self()), "callback" => nil})
  end

  def attempt(writer, callback) do
    writer |> decode() |> Map.put("callback", encode(callback)) |> encode()
  end

  def describe(owner) do
    %{"vm" => vm} = decode(owner)
    "#{vm["nonce"]}; VM OS PID=#{vm["os_pid"]}, node=#{vm["node"]}, start_time=#{vm["start"]}"
  end

  def require_dead(nil), do: :ok

  def require_dead(owner) do
    case decode(owner) do
      %{"format" => 1, "vm" => recorded, "writer" => writer, "callback" => callback}
      when is_map(recorded) and is_binary(writer) ->
        current = vm()
        recorded_start = recorded["start"]

        cond do
          not valid_vm?(recorded) or not valid_pid?(writer, recorded) or
              (callback != nil and not valid_pid?(callback, recorded)) ->
            {:error, {:effect_ownership_unknown, "malformed VM/writer/callback identity"}}

          recorded == current ->
            if dead_pid?(writer) and dead_pid?(callback),
              do: :ok,
              else: {:error, {:effect_owner_alive, description(recorded)}}

          valid_vm?(current) and recorded["machine"] == current["machine"] and
              recorded["boot"] != current["boot"] ->
            :ok

          valid_vm?(current) and recorded["machine"] == current["machine"] and
            recorded["boot"] == current["boot"] and
              recorded["namespace"] == current["namespace"] ->
            case process_start(recorded["os_pid"]) do
              :gone -> :ok
              {:ok, start} when start != recorded_start -> :ok
              {:ok, _} -> {:error, {:effect_owner_alive, description(recorded)}}
              _ -> {:error, {:effect_ownership_unknown, description(recorded)}}
            end

          true ->
            {:error, {:effect_ownership_unknown, description(recorded)}}
        end

      _ ->
        {:error,
         {:effect_ownership_unknown, "missing or unsupported VM/writer/callback identity"}}
    end
  end

  defp valid_vm?(vm) do
    common =
      Enum.all?(
        ["machine", "boot", "namespace", "os_pid", "start", "node", "nonce"],
        &(is_binary(vm[&1]) and vm[&1] != "")
      )

    common and Regex.match?(~r/^[1-9][0-9]*$/, vm["os_pid"]) and
      match?({:ok, <<_::128>>}, Base.decode64(vm["nonce"])) and
      case vm["platform"] do
        "linux" ->
          Regex.match?(~r/^[0-9a-f]{32}$/, vm["machine"]) and
            uuid?(vm["boot"]) and Regex.match?(~r/^pid:\[[0-9]+\]$/, vm["namespace"]) and
            Regex.match?(~r/^[0-9]+$/, vm["start"])

        "darwin" ->
          uuid?(vm["machine"]) and uuid?(vm["boot"]) and vm["namespace"] == "host" and
            Regex.match?(
              ~r/^[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}$/,
              vm["start"]
            )

        _ ->
          false
      end
  end

  defp uuid?(value),
    do: Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, value)

  defp valid_pid?(encoded, vm) do
    case decode(encoded) do
      pid when is_pid(pid) -> Atom.to_string(node(pid)) == vm["node"]
      _ -> false
    end
  end

  defp dead_pid?(nil), do: true

  defp dead_pid?(encoded) do
    case decode(encoded) do
      pid when is_pid(pid) and node(pid) == node() -> not Process.alive?(pid)
      _ -> false
    end
  end

  defp description(vm) do
    "VM OS PID=#{vm["os_pid"]}, node=#{vm["node"]}, start_time=#{vm["start"]}; stop it first"
  end

  defp encode(value), do: value |> :erlang.term_to_binary() |> Base.encode64()

  defp decode(value) when is_binary(value) do
    with {:ok, binary} <- Base.decode64(value), do: :erlang.binary_to_term(binary, [:safe])
  rescue
    ArgumentError -> :unknown
  end

  defp decode(_), do: :unknown

  defp vm do
    :global.trans({__MODULE__, self()}, fn ->
      case :persistent_term.get(__MODULE__, nil) do
        nil ->
          {machine, boot, namespace} = domain()

          start =
            case process_start(System.pid()) do
              {:ok, start} -> start
              _ -> nil
            end

          value = %{
            "machine" => machine,
            "boot" => boot,
            "namespace" => namespace,
            "os_pid" => System.pid(),
            "start" => start,
            "node" => Atom.to_string(node()),
            "platform" => :os.type() |> elem(1) |> Atom.to_string(),
            "nonce" => Base.encode64(:crypto.strong_rand_bytes(16))
          }

          :persistent_term.put(__MODULE__, value)
          value

        value ->
          value
      end
    end)
  end

  defp domain do
    case :os.type() do
      {:unix, :linux} ->
        {read("/etc/machine-id"), read("/proc/sys/kernel/random/boot_id"),
         case File.read_link("/proc/self/ns/pid") do
           {:ok, namespace} -> namespace
           _ -> nil
         end}

      {:unix, :darwin} ->
        {output("ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"])
         |> then(fn value ->
           case Regex.run(~r/"IOPlatformUUID" = "([^"]+)"/, value || "") do
             [_, uuid] -> uuid
             _ -> nil
           end
         end), output("sysctl", ["-n", "kern.bootsessionuuid"]), "host"}

      _ ->
        {nil, nil, nil}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, value} -> String.trim(value)
      _ -> nil
    end
  end

  defp output(command, args) do
    case System.find_executable(command) do
      nil ->
        nil

      executable ->
        case System.cmd(executable, args, env: [{"LC_ALL", "C"}], stderr_to_stdout: true) do
          {value, 0} -> String.trim(value)
          _ -> nil
        end
    end
  end

  defp process_start(pid) when is_binary(pid) do
    case :os.type() do
      {:unix, :linux} ->
        case File.read("/proc/#{pid}/stat") do
          {:ok, stat} ->
            [_, fields] = String.split(stat, ") ", parts: 2)

            case fields |> String.split() |> Enum.at(19) do
              nil -> :unknown
              start -> {:ok, start}
            end

          {:error, :enoent} ->
            :gone

          _ ->
            :unknown
        end

      {:unix, :darwin} ->
        case output("ps", ["-o", "lstart=", "-p", pid]) do
          value when is_binary(value) and value != "" ->
            {:ok, value}

          _ ->
            case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
              {message, 1} ->
                if String.contains?(message, "No such process"), do: :gone, else: :unknown

              _ ->
                :unknown
            end
        end

      _ ->
        :unknown
    end
  end

  defp process_start(_), do: :unknown

  @spec acquire(String.t(), :shared | :exclusive, keyword()) :: {:ok, port()} | {:error, term()}
  def acquire(path, mode, opts \\ []) when mode in [:shared, :exclusive] do
    now = System.monotonic_time(:millisecond)
    deadline = Keyword.get(opts, :deadline, now + 5_000)
    wait_deadline = min(Keyword.get(opts, :wait_deadline, now + 2_000), deadline)
    wait_seconds = Float.to_string(max(wait_deadline - now, 0) / 1_000)
    on_wait = Keyword.get(opts, :on_wait, fn -> :ok end)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         flock when is_binary(flock) <- System.find_executable("flock") do
      flag = if mode == :shared, do: "-s", else: "-x"

      port =
        Port.open({:spawn_executable, flock}, [
          :binary,
          :exit_status,
          {:args, ["-w", wait_seconds, flag, path, "sh", "-c", "printf ready; read stop"]}
        ])

      await_lock(port, path, deadline, on_wait, 300)
    else
      nil -> {:error, :lock_unavailable}
      error -> error
    end
  end

  defp await_lock(port, path, deadline, on_wait, interval) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, "ready"}} ->
        :ok = File.chmod(path, 0o600)
        {:ok, port}

      {^port, {:exit_status, _}} ->
        {:error, :locked}
    after
      min(interval, remaining) ->
        if System.monotonic_time(:millisecond) >= deadline do
          if Port.info(port), do: Port.close(port)
          {:error, :lock_timeout}
        else
          :ok = on_wait.()
          await_lock(port, path, deadline, fn -> :ok end, remaining)
        end
    end
  end

  @spec release(port()) :: :ok | {:error, :lock_release_timeout}
  def release(port) do
    if Port.info(port) do
      Port.command(port, "\n")

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        5_000 -> {:error, :lock_release_timeout}
      end
    else
      :ok
    end
  end
end
