defmodule Elara.Benchmark.Dogfood.Isolation do
  @moduledoc false

  alias Elara.Benchmark.Dogfood.Plan

  @enforce_keys [:root, :workspace, :home, :bin, :source_repo, :source_before, :parent_commit]
  defstruct [:root, :workspace, :home, :bin, :source_repo, :source_before, :parent_commit]

  @type t :: %__MODULE__{
          root: String.t(),
          workspace: String.t(),
          home: String.t(),
          bin: String.t(),
          source_repo: String.t(),
          source_before: String.t(),
          parent_commit: String.t()
        }

  @spec prepare(String.t(), map(), String.t()) :: {:ok, t()} | {:error, term()}
  def prepare(source_repo, task, root)
      when is_binary(source_repo) and is_map(task) and is_binary(root) do
    source_repo = Path.expand(source_repo)
    root = Path.expand(root)
    workspace = Path.join(root, "workspace")
    home = Path.join(root, "home")
    bin = Path.join(root, "bin")
    parent = task["parent_commit"]

    with :ok <- validate_root(source_repo, root) do
      do_prepare(source_repo, root, workspace, home, bin, parent)
    end
  end

  defp do_prepare(source_repo, root, workspace, home, bin, parent) do
    with {:ok, source_before} <- source_fingerprint(source_repo),
         {:ok, _removed} <- File.rm_rf(root),
         :ok <- File.mkdir_p(root),
         {:ok, _output} <-
           command("git", [
             "clone",
             "--no-local",
             "--no-hardlinks",
             "--no-checkout",
             source_repo,
             workspace
           ]),
         {:ok, _output} <- git(workspace, ["checkout", "--detach", parent]),
         {:ok, _output} <- git(workspace, ["remote", "remove", "origin"]),
         :ok <- File.mkdir_p(home),
         :ok <- File.mkdir_p(bin),
         :ok <- install_guards(workspace, home, bin),
         :ok <- verify_guards(workspace, parent) do
      {:ok,
       %__MODULE__{
         root: root,
         workspace: workspace,
         home: home,
         bin: bin,
         source_repo: source_repo,
         source_before: source_before,
         parent_commit: parent
       }}
    else
      {:error, _reason} = error ->
        File.rm_rf(root)
        error
    end
  end

  @spec run(t(), String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, {:exit, non_neg_integer(), String.t()}}
  def run(%__MODULE__{} = isolation, executable, arguments, opts \\ [])
      when is_binary(executable) and is_list(arguments) do
    source = isolation.source_repo

    namespace_script = """
    mount --make-rprivate /
    mount --bind "$1" "$1"
    mount -o remount,bind,ro "$1"
    shift
    exec "$@"
    """

    env =
      [
        "env",
        "-i",
        "HOME=#{isolation.home}",
        "PATH=#{isolation.bin}:/usr/local/bin:/usr/bin:/bin",
        "LANG=C",
        "LC_ALL=C",
        "GIT_TERMINAL_PROMPT=0",
        "GIT_CONFIG_GLOBAL=/dev/null",
        "GIT_CONFIG_SYSTEM=/dev/null",
        "GIT_ASKPASS=/bin/false",
        executable
      ] ++ arguments

    args =
      [
        "--user",
        "--map-root-user",
        "--mount",
        "--fork",
        "sh",
        "-eu",
        "-c",
        namespace_script,
        "sh",
        source
      ] ++ env

    case system_cmd(
           "unshare",
           args,
           [cd: isolation.workspace, stderr_to_stdout: true],
           Keyword.get(opts, :timeout, 30_000)
         ) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:exit, status, output}}
      :timeout -> {:error, {:exit, 124, "isolation command timed out"}}
    end
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  end

  @spec verify_source_unchanged(t()) :: :ok | {:error, :shared_source_changed}
  def verify_source_unchanged(%__MODULE__{} = isolation) do
    case source_fingerprint(isolation.source_repo) do
      {:ok, fingerprint} when fingerprint == isolation.source_before -> :ok
      {:ok, _fingerprint} -> {:error, :shared_source_changed}
      {:error, _reason} -> {:error, :shared_source_changed}
    end
  end

  @spec cleanup(t(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup(%__MODULE__{root: root}, deadline_ms \\ 5_000)
      when is_integer(deadline_ms) and deadline_ms > 0 do
    started = System.monotonic_time(:millisecond)
    File.rm_rf(root)
    elapsed = max(System.monotonic_time(:millisecond) - started, 0)

    cond do
      File.exists?(root) -> {:error, :cleanup_incomplete}
      elapsed > deadline_ms -> {:error, {:cleanup_deadline_exceeded, elapsed, deadline_ms}}
      true -> {:ok, elapsed}
    end
  end

  @spec inert_pilot(Plan.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def inert_pilot(%Plan{} = plan, source_repo, root) do
    [task | _] = Plan.execution_tasks(plan)

    with {:ok, isolation} <- prepare(source_repo, task, root) do
      pilot_result = run_pilot(isolation, task)
      cleanup_result = cleanup(isolation)
      build_pilot_report(plan, pilot_result, cleanup_result)
    end
  end

  defp run_pilot(isolation, task) do
    with {:ok, output} <-
           run(
             isolation,
             "sh",
             [
               "-eu",
               "-c",
               "printf pilot > pilot-marker; ! git push; ! printf forbidden > \"$1/mix.exs\"",
               "sh",
               isolation.source_repo
             ]
           ),
         true <- File.read!(Path.join(isolation.workspace, "pilot-marker")) == "pilot",
         :ok <- verify_guards(isolation.workspace, task["parent_commit"]),
         :ok <- verify_source_unchanged(isolation) do
      {:ok, output}
    else
      false -> {:error, :pilot_marker_missing}
      {:error, _reason} = error -> error
    end
  end

  defp build_pilot_report(plan, {:ok, output}, {:ok, cleanup_ms}) do
    {:ok,
     %{
       "schema" => "elara.exp003.dogfood-report.v1",
       "mode" => "inert_pilot",
       "status" => "passed",
       "plan_sha256" => plan.sha256,
       "target_commit" => plan.data["target"]["commit"],
       "task_results" => [],
       "safety_disqualifiers" => [],
       "harness_errors" => [],
       "pilot" => %{
         "disposable_clone" => true,
         "detached_parent_verified" => true,
         "git_object_sharing" => false,
         "remotes_present" => false,
         "push_blocked" => true,
         "shared_source_read_only" => true,
         "shared_source_unchanged" => true,
         "credential_values_in_environment" => false,
         "cleanup_complete" => true,
         "cleanup_ms" => cleanup_ms,
         "process_output_sha256" => sha256(output),
         "real_task_runs" => 0,
         "fault_runs" => 0
       }
     }}
  end

  defp build_pilot_report(_plan, {:error, reason}, cleanup_result),
    do: {:error, {:pilot_failed, reason, cleanup_result}}

  defp build_pilot_report(_plan, {:ok, _output}, {:error, reason}),
    do: {:error, {:pilot_cleanup_failed, reason}}

  defp install_guards(workspace, home, bin) do
    hooks = Path.join(home, "git-hooks")
    git_wrapper = Path.join(bin, "git")
    real_git = System.find_executable("git")

    wrapper = """
    #!/bin/sh
    for arg in "$@"; do
      case "$arg" in
        -*) ;;
        push|send-pack|receive-pack)
          echo "dogfood isolation: push disabled" >&2
          exit 126
          ;;
        *) break ;;
      esac
    done
    exec #{real_git} "$@"
    """

    pre_push = "#!/bin/sh\necho \"dogfood isolation: push disabled\" >&2\nexit 126\n"

    with :ok <- File.mkdir_p(hooks),
         :ok <- File.write(git_wrapper, wrapper),
         :ok <- File.chmod(git_wrapper, 0o700),
         :ok <- File.write(Path.join(hooks, "pre-push"), pre_push),
         :ok <- File.chmod(Path.join(hooks, "pre-push"), 0o700),
         {:ok, _output} <- git(workspace, ["config", "core.hooksPath", hooks]),
         {:ok, _output} <- git(workspace, ["config", "push.default", "nothing"]),
         {:ok, _output} <- git(workspace, ["config", "credential.helper", ""]) do
      :ok
    end
  end

  defp verify_guards(workspace, parent_commit) do
    alternates = Path.join([workspace, ".git", "objects", "info", "alternates"])

    with {:ok, ^parent_commit} <- git(workspace, ["rev-parse", "HEAD"]),
         {:ok, ""} <- git(workspace, ["remote"]),
         false <- File.exists?(alternates) do
      :ok
    else
      value -> {:error, {:isolation_guard_failed, value}}
    end
  end

  defp validate_root(source_repo, root) do
    cond do
      root == source_repo -> {:error, :isolation_root_is_source}
      descendant?(root, source_repo) -> {:error, :isolation_root_inside_source}
      descendant?(source_repo, root) -> {:error, :source_inside_isolation_root}
      true -> :ok
    end
  end

  defp descendant?(path, possible_parent) do
    relative = Path.relative_to(path, possible_parent)
    relative != path and relative != "." and not String.starts_with?(relative, "../")
  end

  defp source_fingerprint(repo) do
    with {:ok, head} <- git(repo, ["rev-parse", "HEAD"]),
         {:ok, status} <- git(repo, ["status", "--porcelain=v1", "--untracked-files=all"]),
         {:ok, diff} <- command("git", ["diff", "--binary", "HEAD"], cd: repo) do
      {:ok, sha256(head <> <<0>> <> status <> <<0>> <> diff)}
    end
  end

  defp git(cwd, arguments), do: command("git", arguments, cd: cwd, trim: true)

  defp command(executable, arguments, opts \\ []) do
    system_opts =
      [stderr_to_stdout: true]
      |> then(fn system_opts ->
        case Keyword.fetch(opts, :cd) do
          {:ok, cwd} -> Keyword.put(system_opts, :cd, cwd)
          :error -> system_opts
        end
      end)

    case System.cmd(executable, arguments, system_opts) do
      {output, 0} ->
        {:ok, if(Keyword.get(opts, :trim, false), do: String.trim(output), else: output)}

      {_output, status} ->
        {:error, {:command_exit, executable, status}}
    end
  rescue
    error -> {:error, {:command_exception, executable, Exception.message(error)}}
  end

  defp system_cmd(executable, arguments, options, timeout) do
    task = Task.async(fn -> System.cmd(executable, arguments, options) end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        :timeout
    end
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
