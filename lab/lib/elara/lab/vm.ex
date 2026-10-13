defmodule Elara.Lab.VM do
  @moduledoc "Owned disposable external BEAM lifecycle; an exited Port never authorizes a PID kill."
  use GenServer
  alias Elara.Lab.ProcessProbe

  def start(root, name, module, arguments) do
    GenServer.start(__MODULE__, {self(), root, name, module, arguments})
  end

  def snapshot(pid), do: GenServer.call(pid, :snapshot)
  def kill(pid), do: GenServer.call(pid, :kill)

  def ancestry(pid, owner), do: ancestry(pid, owner, 4)
  defp ancestry(owner, owner, _remaining), do: []
  defp ancestry(_pid, _owner, 0), do: throw(:unknown_vm_parent_chain)

  defp ancestry(pid, owner, remaining) do
    {:ok, parent} = ProcessProbe.parent(pid)

    {image, 0} =
      System.cmd("ps", ["-p", to_string(parent), "-o", "comm="], stderr_to_stdout: true)

    true = parent == owner or String.contains?(image, "erl_child_setup")
    [%{pid: parent, image: String.trim(image)} | ancestry(parent, owner, remaining - 1)]
  end

  def stop(pid) do
    if Process.alive?(pid) do
      kill(pid)

      settled =
        wait(
          fn ->
            state = snapshot(pid)
            state.exit_status != nil and state.port_down and ProcessProbe.stopped?(state.os_pid)
          end,
          5_000
        )

      state = snapshot(pid)
      GenServer.stop(pid)
      Map.put(state, :stopped, settled == true)
    else
      %{stopped: false, error: :missing_vm_owner}
    end
  end

  def wait(fun, timeout), do: poll(fun, System.monotonic_time(:millisecond) + timeout)

  defp poll(fun, deadline) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          nil
        else
          Process.sleep(10)
          poll(fun, deadline)
        end
    end
  end

  def write(root, name, value) do
    path = Path.join(root, name <> ".json")
    File.write!(path <> ".tmp", JSON.encode!(value), [:sync])
    File.rename!(path <> ".tmp", path)
  end

  def read(root, name) do
    with {:ok, bytes} <- File.read(Path.join(root, name <> ".json")),
         {:ok, value} <- JSON.decode(bytes),
         do: value,
         else: (_ -> nil)
  end

  @impl true
  def init({owner, root, name, module, arguments}) do
    ref = Process.monitor(owner)

    paths =
      :code.get_path() |> Enum.map(&to_string/1) |> Enum.filter(&(Path.type(&1) == :absolute))

    args =
      ["--erl", "+S 2:2"] ++
        Enum.flat_map(paths, &["-pa", &1]) ++
        ["-e", inspect(module) <> ".run(System.argv())", "--" | arguments]

    cleared =
      for {name, _} <- System.get_env(),
          String.starts_with?(name, "ELARA_") or name == "XAI_API_KEY",
          do: {to_charlist(name), false}

    port =
      Port.open(
        {:spawn_executable, to_charlist(System.find_executable("elixir"))},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, args},
          {:cd, root},
          {:env, cleared ++ [{~c"HOME", to_charlist(Path.join(root, "home"))}]}
        ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    monitor = Port.monitor(port)

    {:ok,
     %{
       port: port,
       os_pid: os_pid,
       monitor: monitor,
       owner: ref,
       log: Path.join(root, name <> "-vm.log"),
       exit_status: nil,
       port_down: false
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    owned =
      Port.info(state.port, :connected) == {:connected, self()} and
        Port.info(state.port, :os_pid) == {:os_pid, state.os_pid}

    {:reply, Map.put(state, :port_owned, owned), state}
  end

  def handle_call(:kill, _from, state), do: {:reply, kill_owned(state), state}

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    File.write!(state.log, bytes, [:append])
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:noreply, %{state | exit_status: status}}

  def handle_info({:DOWN, ref, :port, _port, _reason}, %{monitor: ref} = state),
    do: {:noreply, %{state | port_down: true}}

  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{owner: ref} = state) do
    kill_owned(state)
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state), do: kill_owned(state)

  defp kill_owned(state) do
    if Port.info(state.port, :connected) == {:connected, self()} and
         Port.info(state.port, :os_pid) == {:os_pid, state.os_pid} do
      case System.cmd("kill", ["-KILL", to_string(state.os_pid)], stderr_to_stdout: true) do
        {_, 0} -> :ok
        result -> {:error, result}
      end
    else
      {:error, :exited_or_unowned_port}
    end
  end
end
