defmodule Elara.TestJobs.Workspace do
  @moduledoc false

  def target(cwd, target) when is_binary(target) do
    with [_, path | _] <-
           Regex.run(~r/\A(test\/[^:\x00]+_test\.exs)(?::([1-9][0-9]*))?\z/, target),
         false <- ".." in Path.split(path),
         true <- File.regular?(Path.join(cwd, path)),
         true <- File.regular?(Path.join(cwd, "mix.exs")) do
      :ok
    else
      _ -> {:error, :invalid_test_target}
    end
  end

  def target(_, _), do: {:error, :invalid_test_target}

  # Deliberately a declared source set, not a claim of an isolated filesystem.
  def fingerprint(cwd) do
    paths =
      (Path.wildcard(Path.join(cwd, "{lib,config,test}/**/*"), match_dot: true) ++
         Enum.map(["mix.exs", "mix.lock"], &Path.join(cwd, &1)))
      |> Enum.filter(&File.regular?/1)
      |> Enum.uniq()
      |> Enum.sort()

    if length(paths) > 10_000, do: throw(:source_file_limit)

    {hash, _bytes} =
      Enum.reduce(paths, {:crypto.hash_init(:sha256), 0}, fn path, {hash, total} ->
        {:ok, stat} = File.stat(path)
        if total + stat.size > 64 * 1024 * 1024, do: throw(:source_byte_limit)
        bytes = File.read!(path)
        entry = :erlang.term_to_binary({Path.relative_to(path, cwd), bytes})
        {:crypto.hash_update(hash, entry), total + byte_size(bytes)}
      end)

    %{
      "sha256" => Base.encode16(:crypto.hash_final(hash), case: :lower),
      "files" => length(paths),
      "scope" => "mix.exs,mix.lock,lib/**,config/**,test/**"
    }
  rescue
    _ -> %{"error" => "source unavailable"}
  catch
    reason -> %{"error" => Atom.to_string(reason)}
  end

  def changed(%{"sha256" => first}, %{"sha256" => last}), do: first != last
  def changed(_, _), do: "unknown"
end
