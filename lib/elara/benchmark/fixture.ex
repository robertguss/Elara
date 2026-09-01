defmodule Elara.Benchmark.Fixture do
  @moduledoc false

  import Bitwise

  @workspace_schema "elara.workspace.v1"
  @default_excludes ["_build/", "deps/", ".elara/"]

  @spec reset(map(), String.t(), :initial | :expected_no_fault) ::
          {:ok, String.t()} | {:error, term()}
  def reset(task, root, state \\ :initial) when is_map(task) and is_binary(root) do
    with :ok <- validate_root(root),
         {:ok, files, expected_digest} <- fixture_state(task, state),
         :ok <- replace_directory(root, files),
         {:ok, digest} <- digest_directory(root),
         true <- digest == expected_digest do
      {:ok, digest}
    else
      false -> {:error, :reset_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @spec digest_directory(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def digest_directory(root, opts \\ []) when is_binary(root) do
    excludes = Keyword.get(opts, :exclude, @default_excludes)

    with {:ok, files} <- read_directory(root, excludes) do
      {:ok, digest_files(files)}
    end
  end

  @spec digest_files([map()]) :: String.t()
  def digest_files(files) when is_list(files) do
    body =
      files
      |> Enum.sort_by(& &1["path"])
      |> Enum.map(fn file ->
        content = file["content"]

        [
          file["path"],
          <<0>>,
          file["mode"],
          <<0>>,
          Integer.to_string(byte_size(content)),
          <<0>>,
          content,
          <<0>>
        ]
      end)

    [@workspace_schema, <<0>>, body]
    |> IO.iodata_to_binary()
    |> sha256()
  end

  @spec fixture_digest(map()) :: String.t()
  def fixture_digest(task) when is_map(task) do
    fixture = task["fixture"]

    %{
      "task_id" => task["id"],
      "initial_files" => fixture["initial_files"],
      "expected_no_fault_files" => fixture["expected_no_fault_files"],
      "plan" => task["plan"]
    }
    |> canonical_json()
    |> sha256()
  end

  @spec storage_bytes(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def storage_bytes(root, opts \\ []) when is_binary(root) do
    excludes = Keyword.get(opts, :exclude, @default_excludes)

    with {:ok, files} <- read_directory(root, excludes) do
      {:ok, Enum.sum(Enum.map(files, &byte_size(&1["content"])))}
    end
  end

  @spec apply_pre_operation_changes(map(), String.t()) :: :ok | {:error, term()}
  def apply_pre_operation_changes(task, root) when is_map(task) and is_binary(root) do
    task
    |> get_in(["plan", "pre_operation_changes"])
    |> case do
      changes when is_list(changes) ->
        Enum.reduce_while(changes, :ok, fn change, :ok ->
          case apply_pre_operation_change(change, root) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      _other ->
        {:error, :invalid_pre_operation_changes}
    end
  end

  defp fixture_state(
         %{
           "fixture" => %{
             "initial_files" => files,
             "initial_workspace_sha256" => digest
           }
         },
         :initial
       )
       when is_list(files) and is_binary(digest) do
    {:ok, files, digest}
  end

  defp fixture_state(
         %{
           "fixture" => %{
             "expected_no_fault_files" => files,
             "expected_no_fault_workspace_sha256" => digest
           }
         },
         :expected_no_fault
       )
       when is_list(files) and is_binary(digest) do
    {:ok, files, digest}
  end

  defp fixture_state(_task, state), do: {:error, {:unknown_fixture_state, state}}

  defp replace_directory(root, files) do
    with {:ok, _removed} <- File.rm_rf(root),
         :ok <- File.mkdir_p(root) do
      Enum.reduce_while(files, :ok, fn file, :ok ->
        case write_file(root, file) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp write_file(root, %{"path" => path, "mode" => mode, "content" => content}) do
    with :ok <- validate_path(path),
         {:ok, parsed_mode} <- parse_mode(mode) do
      target = Path.join(root, path)

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(target, content),
           :ok <- File.chmod(target, parsed_mode) do
        :ok
      end
    end
  end

  defp write_file(_root, _file), do: {:error, :invalid_fixture_file}

  defp apply_pre_operation_change(
         %{
           "kind" => "environment",
           "barrier" => "before_effect_dispatch",
           "path" => path,
           "content" => content
         },
         root
       )
       when is_binary(content) do
    with :ok <- validate_path(path) do
      target = Path.join(root, path)

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(target, content),
           :ok <- File.chmod(target, 0o644) do
        :ok
      end
    end
  end

  defp apply_pre_operation_change(change, _root),
    do: {:error, {:unsupported_pre_operation_change, change}}

  defp read_directory(root, excludes) do
    if File.dir?(root) do
      root
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.reduce_while({:ok, []}, fn path, {:ok, files} ->
        relative = Path.relative_to(path, root)

        if excluded?(relative, excludes) do
          {:cont, {:ok, files}}
        else
          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} ->
              {:cont, {:ok, files}}

            {:ok, %File.Stat{type: :regular, mode: mode}} ->
              case File.read(path) do
                {:ok, content} ->
                  file = %{
                    "path" => relative,
                    "mode" =>
                      mode |> band(0o777) |> Integer.to_string(8) |> String.pad_leading(4, "0"),
                    "content" => content
                  }

                  {:cont, {:ok, [file | files]}}

                {:error, reason} ->
                  {:halt, {:error, {:fixture_read_failed, relative, reason}}}
              end

            {:ok, %File.Stat{type: type}} ->
              {:halt, {:error, {:unsupported_fixture_entry, relative, type}}}

            {:error, reason} ->
              {:halt, {:error, {:fixture_stat_failed, relative, reason}}}
          end
        end
      end)
      |> then(fn
        {:ok, files} -> {:ok, Enum.reverse(files)}
        {:error, _reason} = error -> error
      end)
    else
      {:error, :fixture_root_missing}
    end
  end

  defp excluded?(path, excludes) do
    Enum.any?(excludes, fn prefix ->
      base = String.trim_trailing(prefix, "/")
      path == base or String.starts_with?(path, prefix)
    end)
  end

  defp validate_root(root) do
    expanded = Path.expand(root)

    if expanded in ["/", Path.expand(".")] do
      {:error, :unsafe_fixture_root}
    else
      :ok
    end
  end

  defp validate_path(path) when is_binary(path) do
    cond do
      path == "" -> {:error, :empty_fixture_path}
      Path.type(path) != :relative -> {:error, :absolute_fixture_path}
      Path.relative_to(path, ".") != path -> {:error, :noncanonical_fixture_path}
      ".." in Path.split(path) -> {:error, :unsafe_fixture_path}
      String.contains?(path, <<0>>) -> {:error, :unsafe_fixture_path}
      true -> :ok
    end
  end

  defp validate_path(_path), do: {:error, :invalid_fixture_path}

  defp parse_mode(mode) when is_binary(mode) do
    case Integer.parse(mode, 8) do
      {value, ""} when value >= 0 and value <= 0o777 -> {:ok, value}
      _other -> {:error, :invalid_fixture_mode}
    end
  end

  defp parse_mode(_mode), do: {:error, :invalid_fixture_mode}

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, item} ->
      JSON.encode!(key) <> ":" <> canonical_json(item)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(value) when is_list(value) do
    value
    |> Enum.map_join(",", &canonical_json/1)
    |> then(&("[" <> &1 <> "]"))
  end

  defp canonical_json(value), do: JSON.encode!(value)

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
