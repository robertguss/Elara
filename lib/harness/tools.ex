defmodule Harness.Tools do
  @moduledoc "Built-in tool implementations."

  alias Harness.Tool.Ctx

  @spec read(map(), Ctx.t()) :: Harness.Tool.outcome()
  def read(%{"path" => path}, %Ctx{cwd: cwd}) when is_binary(path) do
    full = Path.expand(path, cwd)

    case File.read(full) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "read failed: #{describe_posix(reason)} (#{path})"}
    end
  end

  def read(_args, _ctx), do: {:error, "read requires path"}

  @spec write(map(), Ctx.t()) :: Harness.Tool.outcome()
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

  @spec edit(map(), Ctx.t()) :: Harness.Tool.outcome()
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

  @spec bash(map(), Ctx.t()) :: Harness.Tool.outcome()
  def bash(%{"command" => command}, %Ctx{cwd: cwd}) when is_binary(command) do
    {out, status} = System.shell(command, cd: cwd, stderr_to_stdout: true)

    if status == 0 do
      {:ok, out}
    else
      {:error, "exit #{status}\n" <> out}
    end
  end

  def bash(_args, _ctx), do: {:error, "bash requires command"}

  defp describe_posix(:enoent), do: "no such file"
  defp describe_posix(:eacces), do: "permission denied"
  defp describe_posix(:eisdir), do: "is a directory"
  defp describe_posix(other), do: inspect(other)
end
