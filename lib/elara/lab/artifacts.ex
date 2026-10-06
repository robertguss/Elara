defmodule Elara.Lab.Artifacts do
  @moduledoc "Read-only source, compiled code and native fingerprints for a frozen lab run."

  def snapshot(repo) do
    {tracked, 0} = System.cmd("git", ["ls-files", "-z"], cd: repo)
    source = String.split(tracked, <<0>>, trim: true) |> Enum.map(&Path.join(repo, &1))
    build = Application.app_dir(:elara) |> Path.dirname() |> Path.dirname()
    beams = Path.wildcard(Path.join(build, "lib/*/ebin/*.beam"))
    consolidated = Path.wildcard(Path.join(build, "lib/*/consolidated/*.beam"))

    shared =
      Path.wildcard(Path.join(build, "lib/*/priv/**/*"))
      |> Enum.filter(&(Path.extname(&1) in [".so", ".dylib"]))

    native = Application.app_dir(:elara, "priv/native/exec-stub")
    files = Map.new(source ++ beams ++ consolidated ++ shared ++ [native], &{&1, hash(&1)})
    true = Enum.all?(files, fn {_, digest} -> is_binary(digest) and byte_size(digest) == 64 end)

    modules =
      Enum.map(beams, fn path ->
        {:ok, {module, md5}} = :beam_lib.md5(to_charlist(path))
        %{file: path, module: Atom.to_string(module), md5: Base.encode16(md5, case: :lower)}
      end)

    %{schema: 1, repo: repo, source: source_state(repo), files: files, modules: modules}
  end

  def verify(manifest) do
    changed =
      for {path, expected} <- manifest["files"],
          not is_binary(expected) or byte_size(expected) != 64 or hash(path) != expected,
          do: path

    modules = Enum.filter(manifest["modules"], &(not loaded_matches?(&1)))
    source = source_state(manifest["repo"]) |> JSON.encode!() |> JSON.decode!()

    %{
      verified:
        manifest["schema"] == 1 and changed == [] and modules == [] and
          source == manifest["source"],
      changed_files: changed,
      changed_modules: Enum.map(modules, & &1["module"]),
      source_matches: source == manifest["source"],
      source: source
    }
  end

  defp source_state(repo) do
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)

    {status, 0} =
      System.cmd("git", ["-c", "core.excludesFile=/dev/null", "status", "--porcelain"], cd: repo)

    %{commit: String.trim(commit), dirty: status != ""}
  end

  defp hash(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      {:error, _} -> nil
    end
  end

  defp loaded_matches?(expected) do
    with {:ok, {module, md5}} <- :beam_lib.md5(to_charlist(expected["file"])),
         true <- Atom.to_string(module) == expected["module"],
         true <- Base.encode16(md5, case: :lower) == expected["md5"] do
      case :code.is_loaded(module) do
        false -> true
        {:file, _path} -> module.module_info(:md5) == md5
      end
    else
      _ -> false
    end
  end
end
