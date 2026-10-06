defmodule Elara.Plugin.Trust do
  @moduledoc "Explicit approval of exact local plugin source bytes, before compilation."

  def snapshot(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, entries} ->
      path = Path.expand(path)

      case File.read(path) do
        {:ok, source} -> {:cont, {:ok, [%{path: path, sha256: digest(source)} | entries]}}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  def check(path, source) do
    if File.read(approval_path(path)) == {:ok, digest(source)},
      do: :ok,
      else: {:error, :plugin_trust_required}
  end

  def approve(entries) do
    with :ok <- File.mkdir_p(root()),
         :ok <- File.chmod(root(), 0o700) do
      Enum.reduce_while(entries, :ok, fn %{path: path, sha256: hash}, :ok ->
        destination = approval_path(path)
        tmp = destination <> ".tmp.#{System.unique_integer([:positive])}"

        result =
          with :ok <- File.write(tmp, hash),
               :ok <- File.chmod(tmp, 0o600),
               :ok <- File.rename(tmp, destination),
               do: :ok

        File.rm(tmp)
        if result == :ok, do: {:cont, :ok}, else: {:halt, result}
      end)
    end
  end

  defp root do
    Application.get_env(:elara, :plugin_trust_root) ||
      Path.join([System.user_home!(), ".elara", "plugin-trust"])
  end

  defp approval_path(path), do: Path.join(root(), digest(Path.expand(path)) <> ".sha256")
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
