defmodule Elara.Effect.AtomicFile do
  @moduledoc false

  defmodule Target do
    @moduledoc false
    @enforce_keys [:cwd, :path, :full_path]
    defstruct [:cwd, :path, :full_path]

    @type t :: %__MODULE__{cwd: String.t(), path: String.t(), full_path: String.t()}
  end

  defmodule Observation do
    @moduledoc false
    @enforce_keys [:state, :path]
    defstruct [:state, :path, :sha256, :reason]

    @type state ::
            :expected_preimage
            | :exact_postimage
            | :conflict
            | :absent
            | :non_file
            | :symlink_rejected
            | :unavailable

    @type t :: %__MODULE__{
            state: state(),
            path: String.t(),
            sha256: String.t() | nil,
            reason: term() | nil
          }
  end

  @type expected :: :absent | {:regular, String.t()}
  @type hook :: (atom() -> :ok)

  @spec target(String.t(), String.t()) :: {:ok, Target.t()} | {:error, :path_outside_workspace}
  def target(path, cwd) when is_binary(path) and is_binary(cwd) do
    if path == "" or Path.type(path) != :relative or path == "." or
         String.contains?(path, <<0>>) do
      {:error, :path_outside_workspace}
    else
      root = Path.expand(cwd)
      full_path = Path.expand(path, root)
      relative = Path.relative_to(full_path, root)
      canonical = path |> Path.split() |> Path.join()

      if path == canonical and Path.type(relative) == :relative and relative != ".." and
           not String.starts_with?(relative, "../") do
        {:ok, %Target{cwd: root, path: path, full_path: full_path}}
      else
        {:error, :path_outside_workspace}
      end
    end
  end

  @spec observe(Target.t(), expected(), String.t()) :: Observation.t()
  def observe(%Target{} = target, expected, desired_sha256) do
    case snapshot(target) do
      :absent ->
        if expected == :absent do
          %Observation{state: :expected_preimage, path: target.path}
        else
          %Observation{state: :absent, path: target.path}
        end

      {:regular, _content, digest} ->
        cond do
          digest == desired_sha256 ->
            %Observation{state: :exact_postimage, path: target.path, sha256: digest}

          expected_digest(expected) == digest ->
            %Observation{state: :expected_preimage, path: target.path, sha256: digest}

          true ->
            %Observation{state: :conflict, path: target.path, sha256: digest}
        end

      {:symlink, link_target} ->
        %Observation{state: :symlink_rejected, path: target.path, reason: link_target}

      {:non_file, type} ->
        %Observation{state: :non_file, path: target.path, reason: type}

      {:unavailable, reason} ->
        %Observation{state: :unavailable, path: target.path, reason: reason}
    end
  end

  @spec snapshot(Target.t()) ::
          :absent
          | {:regular, binary(), String.t()}
          | {:symlink, String.t() | :unknown}
          | {:non_file, atom()}
          | {:unavailable, term()}
  def snapshot(%Target{} = target) do
    components = Path.split(target.path)
    final_index = length(components) - 1

    components
    |> Enum.with_index()
    |> Enum.reduce_while(target.cwd, fn {component, index}, parent ->
      current = Path.join(parent, component)
      final? = index == final_index

      case File.lstat(current) do
        {:ok, %File.Stat{type: :symlink}} ->
          link_target =
            case File.read_link(current) do
              {:ok, value} -> value
              _error -> :unknown
            end

          {:halt, {:result, {:symlink, link_target}}}

        {:ok, %File.Stat{type: :directory}} when not final? ->
          {:cont, current}

        {:ok, %File.Stat{type: :regular}} when final? ->
          case File.read(current) do
            {:ok, content} ->
              {:halt, {:result, {:regular, content, sha256(content)}}}

            {:error, reason} ->
              {:halt, {:result, {:unavailable, {:read_failed, reason}}}}
          end

        {:ok, %File.Stat{type: type}} ->
          {:halt, {:result, {:non_file, type}}}

        {:error, :enoent} ->
          {:halt, {:result, :absent}}

        {:error, reason} ->
          {:halt, {:result, {:unavailable, {:lstat_failed, reason}}}}
      end
    end)
    |> case do
      {:result, result} -> result
      _path -> :absent
    end
  end

  @spec replace(
          Target.t(),
          expected(),
          binary(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, :committed | :already_satisfied} | {:error, term()}
  def replace(
        %Target{} = target,
        expected,
        content,
        desired_sha256,
        job_id,
        operation_digest,
        opts \\ []
      )
      when is_binary(content) and is_binary(job_id) and is_binary(operation_digest) do
    operation_hook = Keyword.get(opts, :operation_hook, &no_fault/1)
    effect_observer = Keyword.get(opts, :effect_observer, &no_fault/1)

    with :ok <- ensure_parents(target),
         %Observation{state: :expected_preimage} <- observe(target, expected, desired_sha256),
         :ok <- invoke_hook(operation_hook, :after_typed_precondition_before_temp_create),
         :ok <- write_temp(target, content, desired_sha256, job_id, operation_digest) do
      case invoke_hook(operation_hook, :after_temp_complete_before_rename) do
        :ok ->
          finish_replace(
            target,
            expected,
            desired_sha256,
            job_id,
            operation_digest,
            effect_observer
          )

        {:error, reason} ->
          cleanup_bound_temp(target, job_id, operation_digest)
          {:error, reason}
      end
    else
      %Observation{} = observation ->
        {:error, {:observation, observation}}

      {:error, reason} ->
        cleanup_bound_temp(target, job_id, operation_digest)
        {:error, reason}
    end
  end

  @spec bound_temp?(Target.t(), String.t(), String.t()) :: boolean()
  def bound_temp?(%Target{} = target, job_id, operation_digest) do
    File.exists?(temp_path(target, job_id, operation_digest))
  end

  @spec cleanup_bound_temp(Target.t(), String.t(), String.t()) :: :ok
  def cleanup_bound_temp(%Target{} = target, job_id, operation_digest) do
    path = temp_path(target, job_id, operation_digest)
    if File.exists?(path), do: File.rm(path)
    :ok
  end

  defp finish_replace(
         target,
         expected,
         desired_sha256,
         job_id,
         operation_digest,
         effect_observer
       ) do
    temp_path = temp_path(target, job_id, operation_digest)

    result =
      case observe(target, expected, desired_sha256) do
        %Observation{state: :expected_preimage} ->
          with :ok <- File.rename(temp_path, target.full_path),
               :ok <- invoke_hook(effect_observer, :primary_target_committed),
               %Observation{state: :exact_postimage} <-
                 observe(target, expected, desired_sha256) do
            {:ok, :committed}
          else
            %Observation{} = observation -> {:error, {:observation, observation}}
            {:error, reason} -> {:error, reason}
          end

        %Observation{state: :exact_postimage} ->
          {:ok, :already_satisfied}

        %Observation{} = observation ->
          {:error, {:observation, observation}}
      end

    cleanup_bound_temp(target, job_id, operation_digest)
    result
  end

  defp write_temp(target, content, desired_sha256, job_id, operation_digest) do
    path = temp_path(target, job_id, operation_digest)

    case File.write(path, content, [:binary, :exclusive]) do
      :ok ->
        case File.read(path) do
          {:ok, written} ->
            if sha256(written) == desired_sha256,
              do: :ok,
              else: {:error, :temp_digest_mismatch}

          {:error, reason} ->
            {:error, {:temp_read_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:temp_write_failed, reason}}
    end
  end

  defp ensure_parents(target) do
    target.path
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.reduce_while(target.cwd, fn component, parent ->
      current = Path.join(parent, component)

      case File.lstat(current) do
        {:ok, %File.Stat{type: :directory}} ->
          {:cont, current}

        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:symlink_component, Path.relative_to(current, target.cwd)}}}

        {:ok, %File.Stat{type: type}} ->
          {:halt, {:error, {:non_directory_component, type}}}

        {:error, :enoent} ->
          case File.mkdir(current) do
            :ok -> {:cont, current}
            {:error, reason} -> {:halt, {:error, {:parent_create_failed, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:parent_observation_failed, reason}}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _parent -> :ok
    end
  end

  defp temp_path(target, job_id, operation_digest) do
    name = ".elara-#{job_id}-#{String.slice(operation_digest, 0, 16)}.tmp"
    Path.join(Path.dirname(target.full_path), name)
  end

  defp expected_digest(:absent), do: nil
  defp expected_digest({:regular, digest}), do: digest

  defp sha256(content) do
    content
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp invoke_hook(hook, point) do
    case hook.(point) do
      :ok -> :ok
      other -> {:error, {:invalid_hook_return, other}}
    end
  end

  defp no_fault(_point), do: :ok
end
