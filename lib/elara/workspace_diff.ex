defmodule Elara.WorkspaceDiff do
  @moduledoc "Private workspace checkpoints and bounded reports; never writes the workspace index or HEAD."

  import Bitwise
  alias Elara.Message.User
  alias Elara.Session.Store

  @file_limit 128 * 1024
  @report_limit 256 * 1024
  @zero String.duplicate("0", 40)
  defstruct [:root, :repo, :active, :error, :origin]

  def open(store) do
    with {:ok, state} <- Store.root(),
         {:ok, root} <- git(store.cwd, ["rev-parse", "--show-toplevel"]) do
      %__MODULE__{
        root: String.trim(root),
        repo: Path.join([state, "_workspace_snapshots", component(store.id)])
      }
      |> open_origin(store)
    else
      _ ->
        %__MODULE__{error: "Workspace diff unavailable: this workspace is not a Git repository."}
    end
  end

  defp open_origin(handle, store) do
    if Map.get(store, :parent_session) do
      ref = "refs/elara/origin"

      result =
        case bank(handle, ["log", "-1", "--format=%B", ref]) do
          {:ok, encoded} ->
            with {:ok, origin} <- JSON.decode(String.trim(encoded)),
                 true <- origin["root"] == handle.root,
                 {:ok, tree} <- bank(handle, ["rev-parse", ref <> "^{tree}"]) do
              {:ok, Map.put(origin, "tree", String.trim(tree))}
            end

          _ ->
            notice =
              if Map.get(store, :context, %{})["source"],
                do:
                  "Unavailable before successor start; showing from there (#{DateTime.utc_now()}).\n",
                else: "Fresh baseline at fork/clone copy time (#{DateTime.utc_now()}).\n"

            origin = %{"root" => handle.root, "entry" => store.leaf, "notice" => notice}

            with {:ok, tree} <- capture(handle),
                 {:ok, commit} <- bank(handle, ["commit-tree", tree, "-m", JSON.encode!(origin)]),
                 {:ok, _} <- bank(handle, ["update-ref", ref, String.trim(commit), @zero]) do
              {:ok, Map.put(origin, "tree", tree)}
            end
        end

      case result do
        {:ok, origin} -> %{handle | origin: origin}
        _ -> %{handle | error: "Workspace diff unavailable: copy/successor baseline failed."}
      end
    else
      handle
    end
  end

  def admit(%{root: nil} = handle, id), do: %{handle | active: id}

  def admit(%{error: error} = handle, id) when not is_nil(error),
    do: %{handle | active: id}

  def admit(handle, id) do
    with {:ok, tree} <- capture(handle),
         {:ok, handle} <- close_at(handle, tree),
         {:ok, _} <- publish(handle, id, tree, nil) do
      %{handle | active: id}
    else
      _ -> %{handle | active: id, error: "Workspace diff unavailable: baseline capture failed."}
    end
  end

  def finish(handle, settled? \\ true)
  def finish(handle, false), do: %{handle | active: nil}
  def finish(%{active: nil} = handle, true), do: handle
  def finish(%{error: error} = handle, true) when not is_nil(error), do: %{handle | active: nil}

  def finish(handle, true) do
    with {:ok, tree} <- capture(handle),
         {:ok, handle} <- close_at(handle, tree) do
      handle
    else
      _ -> %{handle | error: "Workspace diff unavailable: endpoint capture failed."}
    end
  end

  def report(%{error: error}, _store, _scope) when not is_nil(error), do: {:error, error}

  def report(handle, store, scope) when scope in [:turn, :session] do
    ids = current_turns(handle, store)

    origin =
      if handle.origin,
        do: %{before: handle.origin["tree"], tree: handle.origin["tree"], closed?: true}

    with {:ok, latest} <-
           if(ids == [] and scope == :session and origin,
             do: {:ok, origin},
             else: checkpoint(handle, List.last(ids))
           ),
         {:ok, first} <-
           if(scope == :session and origin,
             do: {:ok, origin},
             else:
               checkpoint(
                 handle,
                 if(scope == :session, do: List.first(ids), else: List.last(ids))
               )
           ),
         {:ok, current} <- capture(handle),
         {:ok, _} <- keep_live(handle, current),
         endpoint = if(latest.closed?, do: latest.tree, else: current),
         {:ok, changes} <- compare(handle, first.before, endpoint),
         {:ok, outside} <- outside_changes(handle, ids, current, scope) do
      text =
        "Scope: git-visible files; ignored files not shown. Submodules: gitlink-only.\n" <>
          if(scope == :session, do: "Session net diff", else: "Latest turn") <>
          if(latest.closed?,
            do: " · closed endpoint\n",
            else: " · live workspace (endpoint not sealed)\n"
          ) <>
          if(scope == :session and handle.origin, do: handle.origin["notice"], else: "") <>
          changes <> outside

      {:ok, text}
    else
      _ -> {:error, "Workspace diff unavailable: no complete baseline for this session path."}
    end
  end

  defp current_turns(handle, store) do
    entries = Map.new(store.entries, &{&1.id, &1})
    ancestors(entries, store.leaf, if(handle.origin, do: handle.origin["entry"]), [])
  end

  defp ancestors(_entries, id, stop, acc) when is_nil(id) or id == stop, do: acc

  defp ancestors(entries, id, stop, acc) do
    entry = Map.fetch!(entries, id)

    ancestors(
      entries,
      entry.parent_id,
      stop,
      if(is_struct(entry.message, User), do: [id | acc], else: acc)
    )
  end

  defp close_at(%{active: nil} = handle, _tree), do: {:ok, handle}

  defp close_at(handle, tree) do
    with {:ok, record} <- checkpoint(handle, handle.active),
         {:ok, _} <- publish(handle, handle.active, tree, record.commit) do
      {:ok, %{handle | active: nil}}
    end
  end

  defp publish(handle, id, tree, parent) do
    ref = turn_ref(id)
    metadata = JSON.encode!(%{version: 1, root: handle.root, entry: id})
    args = ["commit-tree", tree] ++ if(parent, do: ["-p", parent], else: []) ++ ["-m", metadata]

    with {:ok, commit} <- bank(handle, args),
         {:ok, _} <- bank(handle, ["update-ref", ref, String.trim(commit), parent || @zero]) do
      {:ok, String.trim(commit)}
    end
  end

  defp keep_live(handle, tree) do
    with {:ok, commit} <- bank(handle, ["commit-tree", tree, "-m", "Live workspace inspection"]),
         {:ok, _} <- bank(handle, ["update-ref", "refs/elara/live", String.trim(commit)]) do
      {:ok, commit}
    end
  end

  defp checkpoint(_handle, nil), do: {:error, :missing_checkpoint}

  defp checkpoint(handle, id) do
    ref = turn_ref(id)

    with {:ok, message} <- bank(handle, ["log", "-1", "--format=%B", ref]),
         {:ok, %{"version" => 1, "root" => root, "entry" => ^id}} <-
           JSON.decode(String.trim(message)),
         true <- root == handle.root,
         {:ok, graph} <- bank(handle, ["rev-list", "--parents", "-n", "1", ref]),
         [commit | parents] when length(parents) <= 1 <- String.split(String.trim(graph)),
         {:ok, tree} <- bank(handle, ["rev-parse", commit <> "^{tree}"]),
         {:ok, before} <-
           bank(handle, ["rev-parse", (List.first(parents) || commit) <> "^{tree}"]) do
      {:ok,
       %{
         commit: commit,
         tree: String.trim(tree),
         before: String.trim(before),
         closed?: parents != []
       }}
    else
      _ -> {:error, :missing_checkpoint}
    end
  end

  defp capture(handle) do
    with :ok <- File.mkdir_p(handle.repo),
         :ok <- File.chmod(handle.repo, 0o700),
         {:ok, _} <- bank(handle, ["init", "--bare", "--quiet", handle.repo]),
         {:ok, tracked} <- git(handle.root, ["ls-files", "--stage", "-z"]),
         {:ok, untracked} <-
           git(handle.root, ["ls-files", "--others", "--exclude-standard", "-z"]),
         {:ok, entries} <- workspace_entries(handle, tracked, untracked),
         {:ok, entries} <- hash_files(handle, entries),
         {:ok, _} <- bank(handle, ["read-tree", "--empty"]),
         {:ok, _} <- write_index(handle, index_records(entries)),
         {:ok, tree} <- bank(handle, ["write-tree"]) do
      {:ok, String.trim(tree)}
    end
  end

  defp workspace_entries(handle, tracked, untracked) do
    tracked =
      for record <- String.split(tracked, <<0>>, trim: true), into: %{} do
        [metadata, path] = String.split(record, "\t", parts: 2)
        [mode, oid, _stage] = String.split(metadata)
        {path, {mode, oid}}
      end

    paths =
      (Map.keys(tracked) ++ String.split(untracked, <<0>>, trim: true))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, entries} ->
      full = Path.join(handle.root, path)

      case File.lstat(full) do
        {:error, :enoent} ->
          {:cont, {:ok, entries}}

        {:ok, %{type: :regular, mode: mode}} ->
          entry = %{
            path: path,
            source: full,
            mode: if(band(mode, 0o111) != 0, do: "100755", else: "100644")
          }

          {:cont, {:ok, [entry | entries]}}

        {:ok, %{type: :symlink}} ->
          with {:ok, target} <- File.read_link(full),
               source = Path.join(handle.repo, "link-" <> component(path)),
               :ok <- File.write(source, target) do
            {:cont, {:ok, [%{path: path, source: source, mode: "120000"} | entries]}}
          else
            _ -> {:halt, {:error, :unreadable_link}}
          end

        {:ok, %{type: :directory}} ->
          case Map.get(tracked, path) do
            {"160000", oid} ->
              revision =
                case git(full, ["rev-parse", "HEAD"]) do
                  {:ok, value} -> String.trim(value)
                  _ -> oid
                end

              {:cont, {:ok, [%{path: path, oid: revision, mode: "160000"} | entries]}}

            _ ->
              {:halt, {:error, :unsupported_directory}}
          end

        _ ->
          {:halt, {:error, :unreadable_file}}
      end
    end)
  end

  defp hash_files(handle, entries) do
    entries
    |> Enum.chunk_every(100)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      files = Enum.filter(chunk, &Map.has_key?(&1, :source))

      case bank(handle, ["hash-object", "-w", "--no-filters", "--" | Enum.map(files, & &1.source)]) do
        {:ok, output} ->
          hashes = String.split(output, "\n", trim: true)

          if length(hashes) == length(files) do
            mapped = Map.new(Enum.zip(Enum.map(files, & &1.path), hashes))
            {:cont, {:ok, acc ++ Enum.map(chunk, &Map.put_new(&1, :oid, mapped[&1.path]))}}
          else
            {:halt, {:error, :incomplete_hashes}}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  defp index_records(entries) do
    Enum.map_join(entries, fn entry -> "#{entry.mode} #{entry.oid}\t#{entry.path}" <> <<0>> end)
  end

  defp compare(handle, before, after_tree) do
    with {:ok, raw} <-
           bank(handle, ["diff-tree", "--no-renames", "-r", "--raw", "-z", before, after_tree]) do
      records = String.split(raw, <<0>>, trim: true) |> Enum.chunk_every(2)

      Enum.reduce_while(records, {:ok, ""}, fn [metadata, path], {:ok, text} ->
        [old_mode, new_mode, old_oid, new_oid, _status] = String.split(metadata)

        with {:ok, old_size} <- blob_size(handle, old_oid, old_mode),
             {:ok, new_size} <- blob_size(handle, new_oid, new_mode),
             {:ok, diff} <-
               file_diff(
                 handle,
                 before,
                 after_tree,
                 path,
                 old_mode,
                 new_mode,
                 old_oid,
                 new_oid,
                 old_size,
                 new_size
               ) do
          if byte_size(text) + byte_size(diff) > @report_limit do
            {:halt, {:ok, text <> "\nRemaining file contents omitted: report exceeds 256 KiB.\n"}}
          else
            {:cont, {:ok, text <> diff}}
          end
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, ""} -> {:ok, "No changes.\n"}
        result -> result
      end
    end
  end

  defp blob_size(_handle, _oid, mode) when mode in [":000000", "000000", ":160000", "160000"],
    do: {:ok, 0}

  defp blob_size(handle, oid, _mode) do
    with {:ok, size} <- bank(handle, ["cat-file", "-s", oid]),
         do: {:ok, String.to_integer(String.trim(size))}
  end

  defp file_diff(
         handle,
         before,
         after_tree,
         path,
         old_mode,
         new_mode,
         old_oid,
         new_oid,
         old_size,
         new_size
       ) do
    cond do
      old_mode == ":160000" or new_mode == "160000" ->
        {:ok,
         "#{inspect(path)}: submodule gitlink #{old_oid} → #{new_oid} (contents not shown)\n"}

      max(old_size, new_size) > @file_limit ->
        {:ok,
         "#{inspect(path)}: large file #{old_size} → #{new_size} bytes (contents not shown)\n"}

      true ->
        with {:ok, old} <- blob(handle, old_oid, old_mode),
             {:ok, new} <- blob(handle, new_oid, new_mode) do
          if not String.valid?(old) or not String.valid?(new) or
               :binary.match(old <> new, <<0>>) != :nomatch do
            {:ok,
             "#{inspect(path)}: binary file #{old_size} → #{new_size} bytes (contents not shown)\n"}
          else
            bank(handle, [
              "diff",
              "--no-ext-diff",
              "--no-textconv",
              "--no-color",
              "--no-renames",
              "--no-prefix",
              before,
              after_tree,
              "--",
              path
            ])
          end
        end
    end
  end

  defp blob(_handle, _oid, mode) when mode in [":000000", "000000"], do: {:ok, ""}
  defp blob(handle, oid, _mode), do: bank(handle, ["cat-file", "blob", oid])

  defp outside_changes(handle, ids, current, scope) do
    pairs =
      if(scope == :session, do: ids, else: Enum.take(ids, -2))
      |> Stream.chunk_every(2, 1, :discard)

    gaps =
      Stream.map(pairs, fn [left, right] ->
        with {:ok, %{closed?: true} = previous} <- checkpoint(handle, left),
             {:ok, next} <- checkpoint(handle, right) do
          compare(handle, previous.tree, next.before)
        else
          _ -> {:ok, "Outside-edit boundary unavailable.\n"}
        end
      end)

    gaps =
      if scope == :session and handle.origin do
        initial =
          Stream.map([List.first(ids)], fn id ->
            with {:ok, first} <-
                   if(id, do: checkpoint(handle, id), else: {:ok, %{before: current}}) do
              compare(handle, handle.origin["tree"], first.before)
            end
          end)

        Stream.concat(initial, gaps)
      else
        gaps
      end

    gaps =
      case checkpoint(handle, List.last(ids)) do
        {:ok, %{closed?: true} = latest} ->
          Stream.concat(gaps, Stream.map([latest], &compare(handle, &1.tree, current)))

        _ ->
          gaps
      end

    Enum.reduce_while(gaps, {:ok, ""}, fn
      {:ok, "No changes.\n"}, acc ->
        {:cont, acc}

      {:ok, text}, {:ok, acc} ->
        if byte_size(acc) + byte_size(text) > @report_limit,
          do: {:halt, {:ok, acc <> "Outside changes truncated at 256 KiB.\n"}},
          else: {:cont, {:ok, acc <> text}}

      error, _ ->
        {:halt, error}
    end)
    |> case do
      {:ok, ""} -> {:ok, ""}
      {:ok, changes} -> {:ok, "\nChanged outside Elara (observed between turns):\n" <> changes}
      error -> error
    end
  end

  defp write_index(handle, bytes) do
    input = Path.join(handle.repo, "index-input")

    with :ok <- File.write(input, bytes) do
      try do
        command(
          handle.root,
          "sh",
          [
            "-c",
            "exec git --git-dir=\"$1\" update-index -z --index-info < \"$2\"",
            "sh",
            handle.repo,
            input
          ],
          bank_env(handle)
        )
      after
        File.rm(input)
      end
    end
  end

  defp bank(handle, args),
    do:
      command(
        handle.root,
        "git",
        ["--literal-pathspecs", "--git-dir=" <> handle.repo | args],
        bank_env(handle)
      )

  defp git(cwd, args), do: command(cwd, "git", args, clean_env())

  defp bank_env(handle) do
    clean_env() ++
      [
        {"GIT_INDEX_FILE", Path.join(handle.repo, "capture-index")},
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_CONFIG_SYSTEM", "/dev/null"},
        {"GIT_AUTHOR_NAME", "Elara"},
        {"GIT_AUTHOR_EMAIL", "snapshot@localhost"},
        {"GIT_COMMITTER_NAME", "Elara"},
        {"GIT_COMMITTER_EMAIL", "snapshot@localhost"}
      ]
  end

  defp clean_env do
    Enum.map(
      [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CONFIG_COUNT"
      ],
      &{&1, nil}
    ) ++ [{"GIT_OPTIONAL_LOCKS", "0"}]
  end

  defp command(cwd, executable, args, env) do
    case System.cmd(executable, args, cd: cwd, env: env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _ -> {:error, :git_failed}
    end
  rescue
    ErlangError -> {:error, :git_unavailable}
  end

  defp component(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
  defp turn_ref(id), do: "refs/elara/turns/" <> component(id)
end
