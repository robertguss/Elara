defmodule Elara.Tools.FileFence do
  @moduledoc "Model file-tool policy; internal reads and shell commands are not sandboxed."

  @protected_names ~w(.envrc .iex.exs .profile .bashrc .bash_profile .bash_login .bash_logout
    .zshrc .zshenv .zprofile .zlogin .zlogout .cshrc .tcshrc .kshrc .login .logout)

  def resolve(path, cwd) when is_binary(path) and is_binary(cwd) do
    with :ok <- valid_path(path),
         {:ok, root} <- canonical(cwd),
         {:ok, extras} <- extra_roots(),
         path =
           if(path == "~" or String.starts_with?(path, "~/"), do: Path.expand(path), else: path),
         full = if(Path.type(path) == :absolute, do: path, else: Path.join(cwd, path)),
         :ok <- unprotected(Path.expand(full)),
         {:ok, resolved} <- canonical(full),
         :ok <- unprotected(resolved),
         allowed when is_binary(allowed) <- Enum.find([root | extras], &inside?(resolved, &1)) do
      {:ok, {allowed, resolved}}
    else
      nil -> refusal(:path_outside_workspace)
      {:error, reason} -> refusal(reason)
    end
  end

  defp valid_path(path) do
    if path == "" or String.contains?(path, <<0>>),
      do: {:error, :invalid_path},
      else: :ok
  end

  defp extra_roots do
    System.get_env("ELARA_FILE_ROOTS", "")
    |> String.split(":", trim: true)
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, roots} ->
      with true <- Path.type(path) == :absolute,
           {:ok, resolved} <- canonical(path),
           true <- File.dir?(resolved) do
        {:cont, {:ok, [resolved | roots]}}
      else
        _ -> {:halt, {:error, :invalid_elara_file_roots}}
      end
    end)
  end

  defp unprotected(path) do
    parts = Path.split(path)
    home = System.user_home!()
    {:ok, sessions} = Elara.Session.Store.root()

    protected = [
      Path.join(home, ".elara"),
      Path.join(home, ".ssh"),
      Path.join(home, ".codex/auth.json"),
      sessions,
      Application.get_env(:elara, :plugin_trust_root, Path.join(home, ".elara/plugin-trust"))
    ]

    protected? =
      Enum.any?(parts, &(&1 in @protected_names)) or
        Enum.any?(Enum.chunk_every(parts, 2, 1, :discard), fn
          [".git", name] -> name in ["hooks", "config"]
          ["fish", "config.fish"] -> true
          _ -> false
        end) or
        Enum.any?(protected, fn root ->
          case canonical(root) do
            {:ok, resolved} -> inside?(path, resolved) or inside?(path, Path.expand(root))
            {:error, _} -> inside?(path, Path.expand(root))
          end
        end)

    if protected?, do: {:error, :protected_path}, else: :ok
  end

  defp inside?(path, "/"), do: String.starts_with?(path, "/")
  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # Walk before normalizing '..': a symlink's parent is its resolved parent.
  defp canonical(path), do: walk(Path.split(Path.absname(path)), "/", 0)

  defp walk(_parts, _parent, links) when links > 40, do: {:error, :symlink_loop}
  defp walk([], parent, _links), do: {:ok, parent}
  defp walk(["/" | rest], _parent, links), do: walk(rest, "/", links)
  defp walk(["." | rest], parent, links), do: walk(rest, parent, links)
  defp walk([".." | rest], parent, links), do: walk(rest, Path.dirname(parent), links)

  defp walk([part | rest], parent, links) do
    current = Path.join(parent, part)

    case File.lstat(current) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(current) do
          target = if Path.type(target) == :absolute, do: target, else: Path.join(parent, target)
          walk(Path.split(target) ++ rest, "/", links + 1)
        end

      {:ok, _stat} ->
        walk(rest, current, links)

      {:error, :enoent} ->
        walk(rest, current, links)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refusal(reason), do: {:error, "file access refused: #{reason}"}
end
