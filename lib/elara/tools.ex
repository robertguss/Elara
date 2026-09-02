defmodule Elara.Tools do
  @moduledoc "Built-in tool implementations."

  alias Elara.Exec
  alias Elara.Tool.Ctx

  @spec read(map(), Ctx.t()) :: Elara.Tool.outcome()
  def read(%{"path" => path}, %Ctx{cwd: cwd}) when is_binary(path) do
    full = Path.expand(path, cwd)

    case File.read(full) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "read failed: #{describe_posix(reason)} (#{path})"}
    end
  end

  def read(_args, _ctx), do: {:error, "read requires path"}

  @spec write(map(), Ctx.t()) :: Elara.Tool.outcome()
  def write(%{"path" => path, "content" => content}, %Ctx{cwd: cwd})
      when is_binary(path) and is_binary(content) do
    full = Path.expand(path, cwd)

    with :ok <- File.mkdir_p(Path.dirname(full)),
         :ok <- File.write(full, content) do
      {:ok, "wrote #{byte_size(content)} bytes to #{path}"}
    else
      {:error, reason} -> {:error, "write failed: #{describe_posix(reason)} (#{path})"}
    end
  end

  def write(_args, _ctx), do: {:error, "write requires path and content"}

  @spec edit(map(), Ctx.t()) :: Elara.Tool.outcome()
  def edit(%{"path" => path, "old_text" => old_text, "new_text" => new_text}, %Ctx{cwd: cwd})
      when is_binary(path) and is_binary(old_text) and is_binary(new_text) do
    full = Path.expand(path, cwd)

    case File.read(full) do
      {:ok, content} ->
        case :binary.matches(content, old_text) do
          [] ->
            {:error, "old_text not found in #{path}"}

          [_] ->
            updated = String.replace(content, old_text, new_text, global: false)

            case File.write(full, updated) do
              :ok -> {:ok, "edited #{path}"}
              {:error, reason} -> {:error, "edit write failed: #{describe_posix(reason)}"}
            end

          matches ->
            {:error, "old_text matched #{length(matches)} times in #{path}; need exactly one"}
        end

      {:error, reason} ->
        {:error, "edit read failed: #{describe_posix(reason)} (#{path})"}
    end
  end

  def edit(_args, _ctx), do: {:error, "edit requires path, old_text, and new_text"}

  @spec bash(map(), Ctx.t()) :: Elara.Tool.outcome()
  def bash(%{"command" => command}, %Ctx{} = ctx) when is_binary(command) do
    case Exec.run(["/bin/sh", "-c", command],
           cwd: ctx.cwd,
           max_bytes: ctx.max_output_bytes || 16_384,
           timeout_ms: ctx.timeout_ms || 30_000
         ) do
      {:ok, result} -> bash_result(result)
      {:error, {:not_started, message}} -> {:error, "execution failed: #{message}"}
      {:indeterminate, _message} = result -> result
    end
  end

  def bash(_args, _ctx), do: {:error, "bash requires command"}

  defp bash_result(%Exec.Result{termination: :exited, code: 0, output: output}),
    do: {:ok, output}

  defp bash_result(%Exec.Result{termination: :exited, code: code, output: output})
       when is_integer(code),
       do: {:error, "exit #{code}\n" <> output}

  defp bash_result(%Exec.Result{termination: :exited, signal: signal, output: output}),
    do: {:error, "signal #{signal}\n" <> output}

  defp bash_result(%Exec.Result{termination: :cancelled}), do: {:error, "cancelled"}
  defp bash_result(%Exec.Result{termination: :timed_out}), do: {:error, "timed out"}

  defp bash_result(%Exec.Result{termination: :truncated} = result) do
    {:error,
     "output truncated: bytes_total=#{result.bytes_total} bytes_sent=#{result.bytes_sent}\n" <>
       result.output}
  end

  defp describe_posix(:enoent), do: "no such file"
  defp describe_posix(:eacces), do: "permission denied"
  defp describe_posix(:eisdir), do: "is a directory"
  defp describe_posix(other), do: inspect(other)
end
