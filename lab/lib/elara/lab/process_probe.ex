defmodule Elara.Lab.ProcessProbe do
  @moduledoc "Read-only OS witnesses for owned lab processes; failed probes stay unknown."

  def info(pid) do
    case System.cmd("ps", ["-p", to_string(pid), "-o", "pid=,pgid=,stat="],
           stderr_to_stdout: true
         ) do
      {"", 1} ->
        {:ok, nil}

      {text, 0} ->
        case parse(String.trim(text)) do
          nil -> {:error, :invalid_ps_row}
          row -> {:ok, row}
        end

      {_, status} ->
        {:error, {:ps_failed, status}}
    end
  end

  def group(pgid) do
    case System.cmd("ps", ["-ax", "-o", "pid=,pgid=,stat="], stderr_to_stdout: true) do
      {text, 0} ->
        rows = text |> String.split("\n", trim: true) |> Enum.map(&parse(String.trim(&1)))

        if Enum.any?(rows, &is_nil/1),
          do: {:error, :invalid_ps_rows},
          else: {:ok, Enum.filter(rows, &(&1.pgid == pgid))}

      {_, status} ->
        {:error, {:ps_failed, status}}
    end
  end

  def parent(pid) do
    case System.cmd("ps", ["-p", to_string(pid), "-o", "ppid="], stderr_to_stdout: true) do
      {text, 0} ->
        case Integer.parse(String.trim(text)) do
          {parent, ""} when parent > 0 -> {:ok, parent}
          _ -> {:error, :invalid_parent}
        end

      {_, status} ->
        {:error, {:parent_probe_failed, status}}
    end
  end

  def cwd(pid) do
    with {text, 0} <-
           System.cmd("lsof", ["-a", "-p", to_string(pid), "-d", "cwd", "-Fn"],
             stderr_to_stdout: true
           ),
         path when is_binary(path) <-
           Enum.find_value(String.split(text, "\n"), fn
             "n" <> path -> path
             _ -> nil
           end),
         do: {:ok, path},
         else: (error -> {:error, error})
  end

  def stopped?(pid) do
    case info(pid) do
      {:ok, nil} -> true
      {:ok, %{stat: "Z" <> _}} -> true
      _ -> false
    end
  end

  defp parse(text) do
    case String.split(text) do
      [pid, pgid, stat] ->
        with {pid, ""} <- Integer.parse(pid),
             {pgid, ""} <- Integer.parse(pgid),
             do: %{pid: pid, pgid: pgid, stat: stat},
             else: (_ -> nil)

      _ ->
        nil
    end
  end
end
