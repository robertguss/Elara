defmodule Elara.Tools.FileFence do
  @moduledoc "Model file-tool policy; internal reads and shell commands are not sandboxed."

  @protected_names ~w(.envrc .iex.exs .profile .bashrc .bash_profile .bash_login .bash_logout
    .zshrc .zshenv .zprofile .zlogin .zlogout .cshrc .tcshrc .kshrc .login .logout)

  def resolve(path, cwd) when is_binary(path) and is_binary(cwd) do
    case valid_path(path) do
      :ok ->
        with {:ok, fence} <- prepare(cwd), do: resolve(path, fence)

      {:error, reason} ->
        refusal(reason)
    end
  end

  def resolve(path, %{} = fence) when is_binary(path) do
    {result, _directories} = resolve(path, fence, MapSet.new())
    result
  end

  @doc "Reuse verified directories within one search invocation; leaves and symlinks are rechecked."
  def resolve(path, %{cwd: cwd, roots: roots, protected: protected}, directories)
      when is_binary(path) do
    with :ok <- valid_path(path),
         path =
           if(path == "~" or String.starts_with?(path, "~/"), do: Path.expand(path), else: path),
         full = if(Path.type(path) == :absolute, do: path, else: Path.join(cwd, path)),
         :ok <- unprotected(Path.expand(full), protected),
         {:ok, resolved, directories} <- canonical(full, directories),
         :ok <- unprotected(resolved, protected),
         allowed when is_binary(allowed) <- Enum.find(roots, &inside?(resolved, &1)) do
      {{:ok, {allowed, resolved}}, directories}
    else
      nil -> {refusal(:path_outside_workspace), directories}
      {:error, reason} -> {refusal(reason), directories}
    end
  end

  @doc "Reuse operator policy within a file-tool invocation; every target still resolves afresh."
  def prepare(cwd) when is_binary(cwd) do
    with {:ok, root} <- canonical(cwd),
         {:ok, extras} <- extra_roots() do
      {:ok, %{cwd: cwd, roots: [root | extras], protected: protected_roots()}}
    else
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

  defp protected_roots do
    home = System.user_home!()
    {:ok, sessions} = Elara.Session.Store.root()

    [
      Path.join(home, ".elara"),
      Path.join(home, ".ssh"),
      Path.join(home, ".codex/auth.json"),
      sessions,
      Application.get_env(:elara, :plugin_trust_root, Path.join(home, ".elara/plugin-trust")),
      Application.get_env(:elara, :mcp_trust_root, Path.join(home, ".elara/mcp-trust")),
      Path.join(Application.get_env(:elara, :mcp_home, home), ".elara")
    ]
    |> Enum.flat_map(fn root ->
      case canonical(root) do
        {:ok, resolved} -> [resolved, Path.expand(root)]
        {:error, _} -> [Path.expand(root)]
      end
    end)
    |> Enum.uniq()
  end

  defp unprotected(path, protected) do
    parts = Path.split(path)

    protected? =
      Enum.any?(parts, &(&1 in @protected_names)) or
        Enum.any?(Enum.chunk_every(parts, 2, 1, :discard), fn
          [".git", name] -> name in ["hooks", "config"]
          ["fish", "config.fish"] -> true
          _ -> false
        end) or
        Enum.any?(protected, &inside?(path, &1))

    if protected?, do: {:error, :protected_path}, else: :ok
  end

  defp inside?(path, "/"), do: String.starts_with?(path, "/")
  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # Walk before normalizing '..': a symlink's parent is its resolved parent.
  defp canonical(path) do
    with {:ok, resolved, _directories} <- canonical(path, MapSet.new()), do: {:ok, resolved}
  end

  defp canonical(path, directories),
    do: walk(Path.split(Path.absname(path)), "/", 0, directories)

  defp walk(_parts, _parent, links, _directories) when links > 40, do: {:error, :symlink_loop}
  defp walk([], parent, _links, directories), do: {:ok, parent, directories}
  defp walk(["/" | rest], _parent, links, dirs), do: walk(rest, "/", links, dirs)
  defp walk(["." | rest], parent, links, dirs), do: walk(rest, parent, links, dirs)
  defp walk([".." | rest], parent, links, dirs), do: walk(rest, Path.dirname(parent), links, dirs)

  defp walk([part | rest], parent, links, directories) do
    current = Path.join(parent, part)

    if rest != [] and MapSet.member?(directories, current) do
      walk(rest, current, links, directories)
    else
      case File.lstat(current) do
        {:ok, %File.Stat{type: :symlink}} ->
          with {:ok, target} <- File.read_link(current) do
            target =
              if Path.type(target) == :absolute, do: target, else: Path.join(parent, target)

            walk(Path.split(target) ++ rest, "/", links + 1, directories)
          end

        {:ok, %File.Stat{type: :directory}} ->
          walk(rest, current, links, MapSet.put(directories, current))

        {:ok, _stat} ->
          walk(rest, current, links, directories)

        {:error, :enoent} ->
          walk(rest, current, links, directories)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp refusal(reason), do: {:error, "file access refused: #{reason}"}
end
