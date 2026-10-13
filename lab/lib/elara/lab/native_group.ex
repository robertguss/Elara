defmodule Elara.Lab.NativeGroup do
  @moduledoc "OS ownership and stop witnesses for the fixed ordinary shell lab fixture."
  alias Elara.Lab.ProcessProbe

  def command do
    """
    printf '%s' "$$" > os_pid
    sleep 60 &
    printf '%s' "$!" > descendant_pid
    printf x >> started
    while [ ! -e release ]; do sleep 0.01; done
    """
  end

  def before(cwd) do
    with {:ok, root_pid} <- read_pid(cwd, "os_pid"),
         {:ok, child_pid} <- read_pid(cwd, "descendant_pid"),
         {:ok, root} when is_map(root) <- ProcessProbe.info(root_pid),
         {:ok, child} when is_map(child) <- ProcessProbe.info(child_pid),
         false <- String.starts_with?(root.stat, "Z") or String.starts_with?(child.stat, "Z"),
         {:ok, parent} <- ProcessProbe.parent(child.pid),
         true <- parent == root.pid and child.pgid == root.pgid,
         {:ok, controller} when is_map(controller) <- ProcessProbe.info(System.pid()),
         true <- root.pgid != controller.pgid,
         {:ok, root_cwd} <- ProcessProbe.cwd(root.pid),
         {:ok, child_cwd} <- ProcessProbe.cwd(child.pid),
         true <- same_directory?(cwd, root_cwd) and same_directory?(cwd, child_cwd),
         {:ok, members} <- ProcessProbe.group(root.pgid),
         true <-
           Enum.all?([root.pid, child.pid], fn pid -> Enum.any?(members, &(&1.pid == pid)) end),
         {:ok, "x"} <- File.read(Path.join(cwd, "started")) do
      %{
        root: Map.put(root, :cwd, root_cwd),
        child: Map.merge(child, %{parent: parent, cwd: child_cwd}),
        controller_pgid: controller.pgid,
        members: members,
        owned: true
      }
    else
      _ -> nil
    end
  end

  def epoch(native) do
    pid = Process.whereis(Elara.Exec)
    status = Elara.Exec.status()
    token = Elara.Exec.token()
    {:links, links} = Process.info(pid, :links)
    port = Enum.find(links, &(is_port(&1) and Port.info(&1, :os_pid) == {:os_pid, status.os_pid}))
    {:ok, guardian} = ProcessProbe.parent(native.root.pid)
    {:ok, stub} = ProcessProbe.parent(guardian)
    {:ok, guardian_info} = ProcessProbe.info(guardian)

    unless status.available and status.jobs == 1 and is_port(port) and
             Port.info(port, :connected) == {:connected, pid} and stub == status.os_pid and
             is_map(guardian_info) and not String.starts_with?(guardian_info.stat, "Z"),
           do: throw(:unwitnessed_group_epoch)

    %{pid: pid, port: port, os_pid: status.os_pid, token: token, guardian: guardian}
  end

  def stopped(%{root: _} = native) do
    with {:ok, members} <- ProcessProbe.group(native.root.pgid),
         {:ok, root} <- ProcessProbe.info(native.root.pid),
         {:ok, child} <- ProcessProbe.info(native.child.pid) do
      guardian = ProcessProbe.stopped?(native.guardian)

      %{
        stopped:
          Enum.all?(members, &String.starts_with?(&1.stat, "Z")) and
            dead_row?(root) and dead_row?(child) and guardian,
        root: root,
        child: child,
        members: members,
        guardian_stopped: guardian,
        stub_stopped: ProcessProbe.stopped?(native.stub)
      }
    else
      error -> %{stopped: false, error: error}
    end
  end

  def stopped(_), do: %{stopped: false, error: :missing_native_witness}
  defp dead_row?(nil), do: true
  defp dead_row?(%{stat: stat}), do: String.starts_with?(stat, "Z")

  defp read_pid(cwd, name) do
    with {:ok, text} <- File.read(Path.join(cwd, name)),
         {pid, ""} when pid > 0 <- Integer.parse(text),
         do: {:ok, pid},
         else: (_ -> :error)
  end

  defp same_directory?(expected, actual) do
    with {:ok, a} <- File.stat(expected),
         {:ok, b} <- File.stat(actual),
         do: a.inode == b.inode and a.major_device == b.major_device,
         else: (_ -> false)
  end
end
