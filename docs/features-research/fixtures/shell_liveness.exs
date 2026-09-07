defmodule ShellLivenessPlugin do
  @behaviour Elara.Plugin

  alias Elara.Plugin.ToolSpec

  @impl true
  def metadata, do: %{id: "shell_liveness", version: "2"}

  @impl true
  def tools do
    [
      %ToolSpec{
        name: "shell_liveness_probe",
        description:
          "Inspect shell fixture liveness for the opaque_shell lifecycle test. Provide cwd and either pid or pid_path; remembers the latest probe as plain session state.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "cwd" => %{
              "type" => "string",
              "description" => "Workspace cwd containing fixture/shell files"
            },
            "pid" => %{"type" => "integer", "description" => "Shell process id, if already known"},
            "pid_path" => %{
              "type" => "string",
              "description" => "File containing the shell process id"
            }
          },
          "additionalProperties" => false
        }
      },
      %ToolSpec{
        name: "shell_liveness_last",
        description: "Return the latest shell liveness probe retained in this session.",
        parameters: empty_schema()
      }
    ]
  end

  @impl true
  def init(_ctx), do: {:ok, %{probe_count: 0, last_probe: nil}}

  @impl true
  def handle_tool("shell_liveness_probe", args, ctx, state) do
    cwd = Map.get(args, "cwd", ctx.cwd)
    pid_path = Map.get(args, "pid_path", Path.join([cwd, "fixture", "shell", "pid"]))
    pid = Map.get(args, "pid") || read_pid(pid_path)

    procfs_state = procfs_state(pid)
    ps_state = ps_state(pid)

    probe = %{
      cwd: cwd,
      pid_path: pid_path,
      pid: pid,
      os: os_name(),
      files: fixture_files(cwd),
      procfs_state: procfs_state,
      ps_state: ps_state,
      portable_liveness: portable_liveness(ps_state, procfs_state)
    }

    next_state = %{probe_count: state.probe_count + 1, last_probe: probe}
    {{:ok, format_probe(next_state.probe_count, probe)}, next_state}
  end

  def handle_tool("shell_liveness_last", _args, _ctx, %{last_probe: nil} = state) do
    {{:ok, "No shell liveness probe has run in this session."}, state}
  end

  def handle_tool("shell_liveness_last", _args, _ctx, state) do
    {{:ok, format_probe(state.probe_count, state.last_probe)}, state}
  end

  def handle_tool(_name, _args, _ctx, state), do: {{:error, "unknown shell liveness tool"}, state}

  defp empty_schema,
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  defp read_pid(path) do
    with true <- is_binary(path),
         {:ok, text} <- File.read(path),
         {pid, ""} <- text |> String.trim() |> Integer.parse() do
      pid
    else
      _ -> nil
    end
  end

  defp fixture_files(cwd) do
    base = Path.join([cwd, "fixture", "shell"])

    for name <- ["pid", "primary.txt", "allow-effect", "allow-exit"], into: %{} do
      path = Path.join(base, name)
      {name, File.exists?(path)}
    end
  end

  defp procfs_state(pid) when is_integer(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        case Regex.run(~r/^\d+ \(.+\) ([A-Z]) /, stat) do
          [_, "Z"] -> :terminated
          [_, _] -> :alive
          _ -> :unknown
        end

      {:error, :enoent} ->
        if File.dir?("/proc"), do: :missing, else: :unavailable

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp procfs_state(_pid), do: :no_pid

  defp ps_state(pid) when is_integer(pid) do
    case System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "stat="], stderr_to_stdout: true) do
      {output, 0} ->
        output |> String.trim() |> classify_ps_stat()

      {output, 1} ->
        if String.trim(output) == "", do: :missing, else: {:error, compact_line(output)}

      {output, status} ->
        {:error, "ps exit #{status}: #{compact_line(output)}"}
    end
  rescue
    _ -> :unknown
  end

  defp ps_state(_pid), do: :no_pid

  defp classify_ps_stat(""), do: :unknown
  defp classify_ps_stat("Z" <> _), do: :terminated
  defp classify_ps_stat(_stat), do: :alive

  defp compact_line(output) do
    output
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 160)
  end

  defp portable_liveness(ps_state, procfs_state) do
    case {ps_state, procfs_state} do
      {state, _} when state in [:alive, :terminated] -> state
      {:missing, _} -> :terminated
      {_, state} when state in [:alive, :terminated] -> state
      {_, :missing} -> :terminated
      {:no_pid, _} -> :no_pid
      {_, :no_pid} -> :no_pid
      _ -> :unknown
    end
  end

  defp os_name do
    {family, name} = :os.type()
    "#{family}:#{name}"
  end

  defp format_probe(count, probe) do
    files =
      probe.files
      |> Enum.sort()
      |> Enum.map_join(", ", fn {name, exists?} -> "#{name}=#{exists?}" end)

    [
      "shell_liveness_probe=#{count}",
      "os=#{probe.os}",
      "cwd=#{probe.cwd}",
      "pid_path=#{probe.pid_path}",
      "pid=#{inspect(probe.pid)}",
      "files: #{files}",
      "procfs_state=#{inspect(probe.procfs_state)}",
      "ps_state=#{inspect(probe.ps_state)}",
      "portable_liveness=#{inspect(probe.portable_liveness)}"
    ]
    |> Enum.join("\n")
  end
end
