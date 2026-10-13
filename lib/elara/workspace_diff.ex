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

  def undo_preview(%{error: error}, _store, _target) when not is_nil(error),
    do: {:error, error}

  def undo_preview(handle, store, target) do
    ids = current_turns(handle, store)

    id =
      if target == :latest do
        Enum.find(Enum.reverse(ids), fn id ->
          match?({:ok, %{closed?: true}}, checkpoint(handle, id))
        end)
      else
        if target in ids, do: target
      end

    with {:ok, %{closed?: true} = record} <- checkpoint(handle, id),
         {:ok, changes} <- raw_changes(handle, record.before, record.tree),
         :ok <- restorable(changes),
         :ok <- undo_preflight(handle, changes),
         {:ok, root} <- File.lstat(handle.root) do
      plan = %{
        id: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
        turn: id,
        root_inode: root.inode,
        root_device: root.major_device,
        changes: changes
      }

      if changes == [] do
        {:error, "Undo unavailable: this turn has no net Git-visible changes."}
      else
        {:ok, plan}
      end
    else
      {:error, text} when is_binary(text) -> {:error, text}
      _ -> {:error, "Undo unavailable: no closed snapshot for this turn on the current path."}
    end
  end

  def undo_apply(handle, plan) do
    with {:ok, %{inode: inode, major_device: device, type: :directory}} <- File.lstat(handle.root),
         true <- inode == plan.root_inode and device == plan.root_device,
         :ok <- undo_preflight(handle, plan.changes),
         {:ok, staged} <- stage_undo(handle, plan),
         :ok <- undo_preflight(handle, plan.changes),
         :ok <-
           save_undo(handle, %{version: 1, id: plan.id, turn: plan.turn, paths: undo_paths(plan)}) do
      result = restore_paths(handle, staged)

      text =
        case result do
          :ok ->
            "Undid Git-visible changes from turn #{plan.turn}."

          {:error, reason} ->
            "Undo of turn #{plan.turn} stopped; changes may be partial: #{inspect(reason)}."
        end

      notice = %Elara.Message.System{
        undo_id: plan.id,
        text: text <> " Files: #{undo_names(undo_paths(plan))}. " <> undo_limits()
      }

      case save_undo(handle, %{version: 1, notice: Store.encode_message(notice)}) do
        :ok ->
          {:notice, notice, result}

        _ ->
          {:error,
           "Undo outcome could not be persisted; reopen to record the interrupted attempt."}
      end
    else
      {:error, text} when is_binary(text) ->
        {:error, text}

      _ ->
        {:error,
         "Undo refused: workspace changed or restore preparation failed; no files restored."}
    end
  end

  def undo_recovery(%{repo: nil}), do: :none

  def undo_recovery(handle) do
    case File.read(undo_record(handle)) do
      {:error, :enoent} -> :none
      {:ok, bytes} -> decode_undo_recovery(bytes)
      _ -> {:error, "Undo recovery record unreadable; no restoration will be replayed."}
    end
  end

  def undo_recorded(handle, id) do
    with :ok <- File.rm(undo_record(handle)) do
      File.rm_rf(Path.join(handle.repo, "undo-stage-" <> component(id)))
      :ok
    end
  end

  def undo_paths(plan), do: Enum.map(plan.changes, & &1.path)

  def undo_limits,
    do:
      "Cannot reverse migrations that ran, ignored folders such as deps/ and _build/, or pushes. Submodules are gitlink-only."

  defp decode_undo_recovery(bytes) do
    case JSON.decode(bytes) do
      {:ok, %{"version" => 1, "notice" => notice}} ->
        case Store.decode_message(notice) do
          {:ok, %Elara.Message.System{} = system} -> {:notice, system}
          _ -> {:error, "Undo recovery record invalid; no restoration will be replayed."}
        end

      {:ok, %{"version" => 1, "id" => id, "turn" => turn, "paths" => paths}}
      when is_binary(id) and id != "" and is_binary(turn) and is_list(paths) ->
        if Enum.all?(paths, &is_binary/1) do
          {:notice,
           %Elara.Message.System{
             undo_id: id,
             text:
               "Undo of turn #{turn} was interrupted; restoration may be partial or uncertain. " <>
                 "Files: #{undo_names(paths)}. No filesystem writes were replayed. " <>
                 undo_limits()
           }}
        else
          {:error, "Undo recovery record invalid; no restoration will be replayed."}
        end

      _ ->
        {:error, "Undo recovery record invalid; no restoration will be replayed."}
    end
  end

  defp restorable(changes) do
    unsupported =
      Enum.filter(changes, fn change ->
        change.before.mode == "160000" or change.after.mode == "160000" or
          not String.valid?(change.path)
      end)

    if unsupported == [],
      do: :ok,
      else:
        {:error,
         "Undo refused: changed submodules or unsupported paths: #{undo_names(Enum.map(unsupported, & &1.path))}. No files restored."}
  end

  defp undo_preflight(handle, changes, removals \\ nil) do
    removals =
      removals ||
        changes
        |> Enum.filter(&(&1.before.mode == "000000"))
        |> MapSet.new(& &1.path)

    conflicts =
      Enum.filter(changes, fn change ->
        case safe_undo_path?(handle, change.path) do
          :ok ->
            current_entry(handle, change.path) != {:ok, change.after} or
              not removable_directory?(handle, change.path, removals)

          {:blocked, ancestor} ->
            change.after.mode != "000000" or not MapSet.member?(removals, ancestor)

          _ ->
            true
        end
      end)

    if conflicts == [],
      do: :ok,
      else:
        {:error,
         "Undo refused: files changed since the turn ended or have unsafe paths: " <>
           "#{undo_names(Enum.map(conflicts, & &1.path))}."}
  end

  defp undo_names(paths), do: inspect(paths, limit: :infinity, printable_limit: :infinity)

  defp removable_directory?(handle, path, removals) do
    full = Path.join(handle.root, path)

    case File.lstat(full) do
      {:ok, %{type: :directory}} ->
        case File.ls(full) do
          {:ok, names} ->
            Enum.all?(names, fn name ->
              child = Path.join(path, name)

              case File.lstat(Path.join(handle.root, child)) do
                {:ok, %{type: :directory}} ->
                  Enum.any?(removals, &String.starts_with?(&1, child <> "/")) and
                    removable_directory?(handle, child, removals)

                {:ok, _} ->
                  MapSet.member?(removals, child)

                _ ->
                  false
              end
            end)

          _ ->
            false
        end

      _ ->
        true
    end
  end

  defp safe_undo_path?(handle, path) do
    parts = Path.split(path)

    if Path.type(path) != :relative or parts == [] or
         Enum.any?(parts, &(&1 in [".", "..", ".git"])) do
      {:error, :unsafe_path}
    else
      parts
      |> Enum.drop(-1)
      |> Enum.reduce_while(handle.root, fn part, parent ->
        child = Path.join(parent, part)

        case File.lstat(child) do
          {:ok, %{type: :directory}} ->
            {:cont, child}

          {:error, :enoent} ->
            {:cont, child}

          {:ok, %{type: type}} when type in [:regular, :symlink] ->
            {:halt, {:blocked, Path.relative_to(child, handle.root)}}

          _ ->
            {:halt, {:error, :unsafe_ancestor}}
        end
      end)
      |> case do
        value when is_binary(value) -> :ok
        error -> error
      end
    end
  end

  defp current_entry(handle, path) do
    full = Path.join(handle.root, path)

    case File.lstat(full) do
      {:error, :enoent} ->
        {:ok, %{mode: "000000", oid: @zero}}

      {:ok, %{type: :directory}} ->
        {:ok, %{mode: "000000", oid: @zero}}

      {:ok, %{type: :symlink}} ->
        with {:ok, target} <- File.read_link(full) do
          oid =
            Base.encode16(:crypto.hash(:sha, "blob #{byte_size(target)}" <> <<0>> <> target),
              case: :lower
            )

          {:ok, %{mode: "120000", oid: oid}}
        end

      {:ok, %{type: :regular, mode: mode}} ->
        with {:ok, oid} <- bank(handle, ["hash-object", "--no-filters", "--", full]) do
          {:ok,
           %{
             mode: if(band(mode, 0o111) != 0, do: "100755", else: "100644"),
             oid: String.trim(oid)
           }}
        end

      _ ->
        {:error, :unsupported_path}
    end
  end

  defp stage_undo(handle, plan) do
    stage = Path.join(handle.repo, "undo-stage-" <> component(plan.id))

    with :ok <- File.mkdir_p(stage) do
      Enum.reduce_while(plan.changes, {:ok, []}, fn change, {:ok, staged} ->
        source = Path.join(stage, component(change.path))

        result =
          if change.before.mode == "000000" do
            :ok
          else
            output = File.stream!(source, [:write, :binary])

            case System.cmd(
                   "git",
                   ["--git-dir=" <> handle.repo, "cat-file", "blob", change.before.oid],
                   cd: handle.root,
                   env: bank_env(handle),
                   into: output
                 ) do
              {_, 0} -> :ok
              _ -> {:error, :missing_baseline_blob}
            end
          end

        case result do
          :ok -> {:cont, {:ok, staged ++ [Map.put(change, :source, source)]}}
          error -> {:halt, error}
        end
      end)
    end
  rescue
    error in [File.Error, ErlangError] -> {:error, Exception.message(error)}
  end

  defp restore_paths(handle, changes) do
    {removals, restorations} = Enum.split_with(changes, &(&1.before.mode == "000000"))
    removed_paths = MapSet.new(removals, & &1.path)

    result =
      Enum.reduce_while(removals ++ restorations, :ok, fn change, :ok ->
        with :ok <- undo_preflight(handle, [change], removed_paths),
             :ok <- restore_path(handle, change, removed_paths) do
          {:cont, :ok}
        else
          false -> {:halt, {:error, :path_changed}}
          error -> {:halt, error}
        end
      end)

    with :ok <- result do
      mismatches =
        Enum.filter(changes, fn change ->
          case safe_undo_path?(handle, change.path) do
            :ok -> current_entry(handle, change.path) != {:ok, change.before}
            {:blocked, _} -> change.before.mode != "000000"
            _ -> true
          end
        end)

      if mismatches == [],
        do: :ok,
        else: {:error, {:restore_verification_failed, Enum.map(mismatches, & &1.path)}}
    end
  end

  defp restore_path(handle, %{before: %{mode: "000000"}} = change, _removals),
    do: File.rm(Path.join(handle.root, change.path))

  defp restore_path(handle, change, removals) do
    destination = Path.join(handle.root, change.path)
    temporary = destination <> ".elara-undo-" <> component(change.source)

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]) do
      File.close(file)

      try do
        result =
          if change.before.mode == "120000" do
            with {:ok, target} <- File.read(change.source),
                 :ok <- File.rm(temporary),
                 do: File.ln_s(target, temporary)
          else
            permissions =
              case File.lstat(destination) do
                {:ok, %{type: :regular, mode: mode}} -> band(mode, 0o666)
                _ -> 0o600
              end

            with :ok <- File.cp(change.source, temporary),
                 do:
                   File.chmod(
                     temporary,
                     if(change.before.mode == "100755",
                       do: bor(permissions, 0o100),
                       else: permissions
                     )
                   )
          end

        with :ok <- result,
             :ok <- safe_undo_path?(handle, change.path),
             true <- current_entry(handle, change.path) == {:ok, change.after},
             :ok <- remove_empty_directory(handle, change.path, removals),
             do: File.rename(temporary, destination)
      after
        File.rm(temporary)
      end
    end
  end

  defp remove_empty_directory(handle, path, removals) do
    full = Path.join(handle.root, path)

    case File.lstat(full) do
      {:ok, %{type: :directory}} ->
        with true <- Enum.any?(removals, &String.starts_with?(&1, path <> "/")),
             {:ok, names} <- File.ls(full),
             :ok <-
               Enum.reduce_while(names, :ok, fn name, :ok ->
                 child = Path.join(path, name)

                 case File.lstat(Path.join(handle.root, child)) do
                   {:ok, %{type: :directory}} ->
                     case remove_empty_directory(handle, child, removals) do
                       :ok -> {:cont, :ok}
                       error -> {:halt, error}
                     end

                   _ ->
                     {:halt, {:error, :directory_not_empty}}
                 end
               end),
             do: File.rmdir(full)

      _ ->
        :ok
    end
  end

  defp save_undo(handle, record) do
    path = undo_record(handle)
    temporary = path <> ".tmp"

    with {:ok, :ok} <-
           File.open(temporary, [:write, :binary, :sync], &IO.binwrite(&1, JSON.encode!(record))),
         :ok <- File.rename(temporary, path),
         do: :ok
  end

  defp undo_record(handle), do: Path.join(handle.repo, "undo-pending.json")

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

  defp raw_changes(handle, before, after_tree) do
    with {:ok, raw} <-
           bank(handle, ["diff-tree", "--no-renames", "-r", "--raw", "-z", before, after_tree]) do
      changes =
        raw
        |> String.split(<<0>>, trim: true)
        |> Enum.chunk_every(2)
        |> Enum.map(fn [metadata, path] ->
          [old_mode, new_mode, old_oid, new_oid, _status] = String.split(metadata)

          %{
            path: path,
            before: %{mode: String.trim_leading(old_mode, ":"), oid: old_oid},
            after: %{mode: new_mode, oid: new_oid}
          }
        end)

      {:ok, changes}
    end
  end

  defp compare(handle, before, after_tree) do
    with {:ok, changes} <- raw_changes(handle, before, after_tree) do
      Enum.reduce_while(changes, {:ok, ""}, fn change, {:ok, text} ->
        %{
          path: path,
          before: %{mode: old_mode, oid: old_oid},
          after: %{mode: new_mode, oid: new_oid}
        } = change

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
      old_mode == "160000" or new_mode == "160000" ->
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
