defmodule Elara.Recordings do
  @moduledoc "Explicit recording retention under the session lock; never background deletion."

  alias Elara.Session.Store

  @magic "ELARA-FLIGHT\0"

  def diagnostics do
    with {:ok, root} <- Store.root() do
      {:ok,
       %{
         recordings_bytes: size(Path.join([root, "*", "*.flight"])),
         retained_output_bytes: size(Path.join([root, "outputs", "*", "*"]))
       }}
    end
  end

  def prune(days, opts \\ []) when is_integer(days) and days >= 0 do
    with {:ok, root} <- Store.root() do
      cutoff = Keyword.get(opts, :now, System.system_time(:second)) - days * 86_400
      apply? = Keyword.get(opts, :apply, false)

      results =
        root
        |> Path.join("*/*.flight")
        |> Path.wildcard()
        |> Enum.map(fn path -> prune_file(path, cutoff, apply?) end)

      {:ok, results}
    end
  end

  def delete(session_path) do
    session_path
    |> Path.rootname()
    |> Kernel.<>("-*.flight")
    |> Path.wildcard()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp prune_file(path, cutoff, apply?) do
    with {:ok, %{type: :regular, mtime: mtime}} <- File.lstat(path, time: :posix),
         true <- mtime < cutoff,
         {:ok, session_path} <- owner(path),
         [] <- Registry.lookup(Elara.SessionLocks, Path.expand(session_path)),
         {:ok, store} <- Store.claim(%Store{path: session_path}) do
      try do
        # Recheck under the same cross-VM lock used before recorder creation.
        case File.lstat(path, time: :posix) do
          {:ok, %{type: :regular, mtime: current, size: bytes}} when current < cutoff ->
            if apply? do
              case File.rm(path) do
                :ok -> %{path: path, bytes: bytes, status: :deleted}
                {:error, reason} -> %{path: path, status: {:error, reason}}
              end
            else
              %{path: path, bytes: bytes, status: :would_delete}
            end

          _ ->
            %{path: path, status: :kept}
        end
      after
        Store.release(store)
      end
    else
      false -> %{path: path, status: :kept}
      [_ | _] -> %{path: path, status: :live}
      {:error, :locked} -> %{path: path, status: :live}
      {:error, reason} -> %{path: path, status: {:error, reason}}
      _ -> %{path: path, status: :kept}
    end
  end

  defp owner(path) do
    Code.ensure_loaded!(Elara.FlightRecorder)

    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        with <<@magic, _version::32, size::32>> <- IO.binread(file, byte_size(@magic) + 8),
             true <- size <= 65_536,
             binary when is_binary(binary) <- IO.binread(file, size),
             %{type: :header, session_id: id} when is_binary(id) <-
               :erlang.binary_to_term(binary, [:safe]),
             true <- Path.basename(path) |> String.starts_with?(id <> "-"),
             true <- Path.basename(id) == id and id not in ["", ".", ".."] do
          {:ok, Path.join(Path.dirname(path), id <> ".jsonl")}
        else
          _ -> {:error, :invalid_recording}
        end
      rescue
        ArgumentError -> {:error, :invalid_recording}
      after
        File.close(file)
      end
    end
  end

  defp size(pattern) do
    pattern
    |> Path.wildcard()
    |> Enum.reduce(0, fn path, total ->
      case File.lstat(path) do
        {:ok, %{type: :regular, size: bytes}} -> total + bytes
        _ -> total
      end
    end)
  end
end
