defmodule Elara.Threads do
  @moduledoc "Durable delegation ownership. Sessions, not coordinators, own child execution."
  use GenServer
  alias Elara.Session.Store

  @limit 4
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def start_child(parent, assignment, opts \\ []),
    do: GenServer.call(__MODULE__, {:start, parent, assignment, opts}, :infinity)

  def list(parent), do: GenServer.call(__MODULE__, {:list, parent})
  def resume(id, opts \\ []), do: GenServer.call(__MODULE__, {:resume, id, opts}, :infinity)
  def integrate(parent, id), do: GenServer.call(__MODULE__, {:integrate, parent, id}, :infinity)
  def cleanup(parent, id), do: GenServer.call(__MODULE__, {:cleanup, parent, id}, :infinity)
  def stop_subtree(parent), do: GenServer.call(__MODULE__, {:stop, parent})
  def managed?(id), do: File.exists?(record_path(id))

  @doc "Canonical direct relationships; text and supplied workspace paths never grant access."
  def related?(a, b) when is_binary(a) and is_binary(b) do
    a == b or match?({:ok, %{"parent_id" => ^a}}, read(b)) or
      match?({:ok, %{"parent_id" => ^b}}, read(a))
  end

  def related?(_, _), do: false
  def record(id), do: read(id)
  def all_records, do: records()

  def navigation(id) do
    children = list(id).children

    case read(id) do
      {:ok, r} ->
        [
          %{
            "id" => r["parent_id"],
            "assignment" => "↑ Return to parent",
            "state" => "parent",
            "cwd" => r["parent_invocation_cwd"] || r["parent_cwd"]
          }
          | children
        ]

      _ ->
        children
    end
  end

  @doc false
  def resume_options(opts) do
    source =
      case Keyword.get(opts, :resume) do
        :latest -> Store.newest(Keyword.get_lazy(opts, :cwd, &File.cwd!/0))
        path when is_binary(path) -> Store.open(path)
        _ -> :none
      end

    case source do
      {:ok, %{id: id, path: path}} ->
        if managed?(id),
          do: canonical_options(id, opts),
          else: {:ok, Keyword.put(opts, :resume, path)}

      _ ->
        {:ok, opts}
    end
  end

  defp canonical_options(id, opts) do
    with {:ok, r} <- read(id),
         false <- r["state"] == "cleaned",
         :ok <- workspace_present(r),
         {:ok, provider} <- provider(opts),
         true <- inspect(elem(provider, 0)) == r["provider"],
         {:ok, saved} <- decode_options(r["options"]) do
      {:ok,
       opts
       |> Keyword.merge(saved)
       |> Keyword.merge(
         provider: restore_model(provider, r),
         pause_inputs: true,
         resume: r["session_path"]
       )}
    else
      true -> {:error, :workspace_cleaned}
      false -> {:error, :provider_mismatch}
      error -> error
    end
  end

  @doc false
  def acquire_slot(id) do
    not managed?(id) or Registry.keys(Elara.ThreadSlots, self()) != [] or
      Enum.any?(1..@limit, fn slot ->
        match?({:ok, _}, Registry.register(Elara.ThreadSlots, slot, id))
      end)
  end

  @doc false
  def release_slot do
    Enum.each(
      Registry.keys(Elara.ThreadSlots, self()),
      &Registry.unregister(Elara.ThreadSlots, &1)
    )
  end

  @doc false
  def lifecycle(id, {:turn_ended, outcome, _}), do: lifecycle(id, {:turn_ended, outcome})

  def lifecycle(id, event) do
    status =
      case event do
        {:turn_started, _} -> "running"
        {:turn_ended, {:completed, _}} -> "completed"
        {:turn_ended, :interrupted} -> "interrupted"
        {:turn_ended, _} -> "failed"
        _ -> nil
      end

    if status && managed?(id) do
      if pid = Process.whereis(__MODULE__), do: send(pid, {:lifecycle, id, status})
    end

    :ok
  end

  def tool do
    %Elara.Tool{
      name: "start_child",
      description:
        "Start independent persistent child work. Four running children maximum. Coding uses a durable clean-HEAD worktree; research shares cwd with read-only tools. Selected assignment/context only by default. No automatic integration or cleanup. Embedded VM exit interrupts children.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "assignment" => %{"type" => "string"},
          "coding" => %{"type" => "boolean"},
          "history" => %{"type" => "boolean"}
        },
        "required" => ["assignment"]
      },
      run: {__MODULE__, :run},
      capabilities: ["delegate"],
      placement: :local,
      mutating: true
    }
  end

  def run(%{"assignment" => assignment} = args, %Elara.Tool.Ctx{session_id: parent}) do
    case start_child(parent, assignment,
           coding: args["coding"] == true,
           history: args["history"] == true
         ) do
      {:ok, record} -> {:ok, JSON.encode!(record)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def run(_, _), do: {:error, "assignment required"}

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:list, parent}, _from, state) do
    {:reply,
     %{
       limit: @limit,
       children: Enum.filter(records(), &(&1["parent_id"] == parent)) |> Enum.map(&view/1)
     }, state}
  end

  def handle_call({:start, parent, assignment, opts}, _from, state) do
    result =
      with true <-
             is_binary(parent) and is_binary(assignment) and String.valid?(assignment) and
               String.trim(assignment) != "" and
               byte_size(assignment) <= 65_536,
           :ok <- capacity(),
           :ok <- if(depth(parent) < 3, do: :ok, else: {:error, :thread_depth_limit_3}),
           %{} = config <- Elara.child_config(parent),
           true <-
             config.allowed_capabilities == :all or "delegate" in config.allowed_capabilities do
        create(parent, assignment, config, opts)
      else
        false -> {:error, :invalid_assignment_or_delegation_restricted}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:resume, id, opts}, _from, state) do
    result =
      with {:ok, record} <- read(id),
           false <- record["state"] == "cleaned",
           :ok <- capacity() do
        case Elara.session_pid(id) do
          {:ok, _} -> {:ok, id}
          _ -> restore(record, opts)
        end
      else
        true -> {:error, :workspace_cleaned}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:integrate, parent, id}, _from, state) do
    result =
      with {:ok, r} <- owned(parent, id),
           true <-
             r["coding"] and r["state"] != "cleaned" and r["integration_state"] != "integrating",
           :ok <- reconciled(id) do
        workspace_operation(id, fn ->
          workspace_operation(parent, fn -> integrate_patch(r) end)
        end)
      else
        false -> {:error, :not_integrable}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:cleanup, parent, id}, _from, state) do
    result =
      with {:ok, r} <- owned(parent, id),
           true <- r["coding"] and r["integration_state"] == "integrated",
           :ok <- reconciled(id) do
        workspace_operation(id, fn -> cleanup_worktree(r) end, true)
      else
        false -> {:error, :unintegrated_work_preserved}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:stop, parent}, _from, state) do
    ids = descendants(parent, records()) ++ [parent]
    Enum.each(ids, &Elara.interrupt/1)

    {:reply,
     {:ok,
      %{requested: ids, outcome: "interrupt requested; dispatched effects may still be settling"}},
     state}
  end

  defp integrate_patch(r) do
    id = r["id"]

    with {:ok, ""} <- git(r["parent_cwd"], ["status", "--porcelain", "--untracked-files=all"]),
         {:ok, revision} <- git(r["parent_cwd"], ["rev-parse", "HEAD"]),
         {:ok, tree} <- capture_tree(r),
         {:ok, patch} <- git(r["cwd"], ["diff", "--binary", r["base_revision"], tree]),
         true <- patch != "",
         path = patch_path(id, patch),
         integration = %{
           "patch" => path,
           "tree" => tree,
           "parent_revision" => String.trim(revision)
         },
         :ok <- File.write(path, patch),
         :ok <- File.chmod(path, 0o600),
         {:ok, _} <- git(r["parent_cwd"], ["apply", "--check", "--index", path]),
         :ok <-
           save(
             Map.merge(r, %{
               "integration_state" => "integrating",
               "integration_tree" => tree,
               "integration_patch" => path
             })
           ),
         {:ok, _} <- git(r["parent_cwd"], ["apply", "--index", path]),
         :ok <-
           save(
             Map.merge(r, %{
               "integration_state" => "integrated",
               "integration_tree" => tree,
               "integration_patch" => path,
               "integrations" => (r["integrations"] || []) ++ [integration]
             })
           ) do
      {:ok, %{patch: path, tree: tree, result: "applied to parent index; not committed"}}
    else
      false -> {:error, :not_integrable}
      {:ok, _dirty} -> {:error, :parent_has_uncommitted_work}
      error -> error
    end
  end

  defp cleanup_worktree(r) do
    with {:ok, tree} <- capture_tree(r),
         true <- tree == r["integration_tree"],
         {:ok, ""} <- git(r["cwd"], ["ls-files", "--others", "--ignored", "--exclude-standard"]),
         {:ok, _} <- git(r["parent_cwd"], ["worktree", "remove", r["cwd"]]),
         :ok <- save(Map.put(r, "state", "cleaned")) do
      :ok
    else
      false -> {:error, :unintegrated_work_preserved}
      {:ok, _} -> {:error, :ignored_files_preserved}
      error -> error
    end
  end

  @impl true
  def handle_info({:lifecycle, id, status}, state) do
    with {:ok, r} <- read(id), true <- r["state"] != "cleaned" do
      save(Map.put(r, "state", status))
    end

    {:noreply, state}
  end

  defp create(parent, assignment, config, opts) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    coding = Keyword.get(opts, :coding, false)

    with {:ok, cwd, base} <- workspace(config.cwd, token, coding),
         {:ok, parent_root} <-
           if(coding,
             do: git(config.cwd, ["rev-parse", "--show-toplevel"]),
             else: {:ok, config.cwd}
           ) do
      tools =
        if coding,
          do: config.tools,
          else:
            Enum.filter(
              config.tools,
              &(&1 in Enum.filter(Elara.Tool.builtins(), fn t ->
                  t.name in ["read", "skill"] or t.run == {Elara.Threads.Communication, :run}
                end))
            )

      caps =
        if coding,
          do: config.allowed_capabilities,
          else: intersect(config.allowed_capabilities, ["filesystem:read"])

      options =
        config.skill_options ++
          [
            cwd: cwd,
            tools: tools,
            plugins: [],
            router: config.router,
            system: config.system,
            allowed_capabilities: caps,
            max_iterations: config.max_iterations,
            max_tool_output_bytes: config.max_tool_output_bytes,
            tool_timeout_ms: config.tool_timeout_ms
          ]

      history = if Keyword.get(opts, :history, false), do: Elara.transcript(parent), else: []
      store = Store.new(cwd, String.slice(assignment, 0, 80))

      with {:ok, store} <-
             Store.set_provider_settings(
               %{store | parent_session: parent},
               Elara.Provider.Visibility.settings(config.provider)
             ) do
        record = %{
          "id" => store.id,
          "parent_id" => parent,
          "assignment" => assignment,
          "cwd" => cwd,
          "parent_cwd" =>
            if(coding, do: String.trim_trailing(parent_root, "\n"), else: parent_root),
          "parent_invocation_cwd" => config.cwd,
          "coding" => coding,
          "base_revision" => base,
          "branch" => if(coding, do: "elara/child-#{token}", else: nil),
          "provider" => inspect(elem(config.provider, 0)),
          "settings" => Elara.Provider.Visibility.settings(config.provider),
          "model" => provider_model(config.provider),
          "allowed_capabilities" => caps,
          "tools" => Enum.map(tools, & &1.name),
          "history" => Keyword.get(opts, :history, false),
          "state" => "prepared",
          "session_path" => store.path,
          "created_at" => System.system_time(:millisecond),
          "options" => Base.encode64(:erlang.term_to_binary(options))
        }

        with :ok <- save(record),
             :ok <- provision_workspace(record),
             {:ok, _id} <-
               Elara.start_session(
                 options ++ [provider: config.provider, seed_history: history, resume: store.path]
               ),
             :ok <- launch(record) do
          {:ok, view(Map.put(record, "state", "running"))}
        end
      end
    end
  end

  defp launch(record) do
    user = %Elara.Message.User{
      text: record["assignment"],
      agent_source: %{
        "sender" => record["parent_id"],
        "recipient" => record["id"],
        "message_id" => "assignment"
      }
    }

    with :ok <- save(Map.put(record, "state", "running")),
         {:ok, _} <-
           Elara.submit_input(record["id"], %{
             id: "assignment",
             sender_id: record["parent_id"],
             kind: :agent,
             user: user
           }),
         do: Elara.resume_inputs(record["id"])
  end

  defp restore(r, opts) do
    with {:ok, id} <- Elara.start_session(Keyword.put(opts, :resume, r["session_path"])),
         :ok <- save(Map.put(r, "state", "interrupted")) do
      # Hydration reconciles effect receipts. Never resubmit the assignment or drain an inbox here.
      {:ok, id}
    end
  end

  defp provider(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, p} -> {:ok, p}
      :error -> Elara.Config.resolve()
    end
  end

  defp decode_options(encoded) do
    # Load built-in atoms before safe decoding in a fresh VM. Custom tool
    # modules must be loaded by their installation, never from disk data.
    Elara.Tool.builtins()
    with {:ok, bytes} <- Base.decode64(encoded), do: {:ok, :erlang.binary_to_term(bytes, [:safe])}
  rescue
    ArgumentError -> {:error, :child_options_unavailable_load_original_tool_modules}
  end

  defp provider_model({_module, config}) when is_map(config), do: Map.get(config, :model)
  defp provider_model(_), do: nil

  defp restore_model({module, config} = provider, r) do
    provider =
      if is_map(config) and is_binary(r["model"]),
        do: {module, Map.put(config, :model, r["model"])},
        else: provider

    Elara.Provider.Visibility.configure(provider, r["settings"])
  end

  defp workspace(cwd, token, true) do
    path = Path.join(root(), "workspaces/#{token}")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, base} <- git(cwd, ["rev-parse", "HEAD"]) do
      {:ok, path, String.trim(base)}
    end
  end

  defp workspace(cwd, _, false), do: {:ok, cwd, nil}
  defp provision_workspace(%{"coding" => false}), do: :ok

  defp provision_workspace(r) do
    with {:ok, _} <-
           git(r["parent_cwd"], [
             "worktree",
             "add",
             "-b",
             r["branch"],
             r["cwd"],
             r["base_revision"]
           ]),
         do: :ok
  end

  defp workspace_present(r) do
    if File.dir?(r["cwd"]) and (not r["coding"] or File.regular?(Path.join(r["cwd"], ".git"))),
      do: :ok,
      else: {:error, :workspace_missing_preserved_record_requires_manual_repair}
  end

  defp intersect(:all, limits), do: limits
  defp intersect(caps, limits), do: Enum.filter(caps, &(&1 in limits))

  defp capacity do
    if Registry.count(Elara.ThreadSlots) < @limit,
      do: :ok,
      else: {:error, :child_concurrency_limit_4}
  end

  defp depth(id) do
    case read(id) do
      {:ok, r} -> 1 + depth(r["parent_id"])
      _ -> 0
    end
  end

  defp reconciled(id) do
    case Elara.transcript(id) do
      history when is_list(history) ->
        if Enum.any?(
             history,
             &match?(%Elara.Message.ToolResult{outcome: {:indeterminate, _}}, &1)
           ), do: {:error, :indeterminate_effects_preserved}, else: :ok

      _ ->
        {:error, :resume_child_before_workspace_operation}
    end
  end

  defp workspace_operation(id, operation, retire? \\ false) do
    case Elara.session_pid(id) do
      {:ok, pid} -> GenServer.call(pid, {:workspace_operation, operation, retire?}, :infinity)
      _ -> operation.()
    end
  end

  defp descendants(parent, records) do
    Enum.flat_map(Enum.filter(records, &(&1["parent_id"] == parent)), fn r ->
      [r["id"] | descendants(r["id"], records)]
    end)
  end

  defp owned(parent, id) do
    with {:ok, r} <- read(id) do
      if r["parent_id"] == parent, do: {:ok, r}, else: {:error, :not_child_of_parent}
    end
  end

  defp view(r) do
    r = Map.delete(r, "options")

    case Elara.status(r["id"]) do
      %{phase: phase} ->
        Map.put(
          r,
          "live_phase",
          if(is_tuple(phase), do: Atom.to_string(elem(phase, 0)), else: Atom.to_string(phase))
        )

      _ ->
        if r["state"] in ["running", "prepared"],
          do:
            Map.merge(r, %{
              "state" => "interrupted/indeterminate",
              "recovery" => "Explicit resume required; no automatic replay"
            }),
          else: r
    end
  end

  defp capture_tree(r) do
    index = Path.join(root(), "index-#{r["id"]}")
    env = [{"GIT_INDEX_FILE", index}]

    try do
      with {:ok, _} <- git(r["cwd"], ["read-tree", "HEAD"], env),
           {:ok, _} <- git(r["cwd"], ["add", "-A"], env),
           {:ok, tree} <- git(r["cwd"], ["write-tree"], env) do
        {:ok, String.trim(tree)}
      end
    after
      File.rm(index)
    end
  end

  defp git(cwd, args, env \\ []) do
    case System.cmd("git", args, cd: cwd, env: env, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, {:git, String.trim(out)}}
    end
  end

  defp root do
    {:ok, root} = Store.root()
    Path.join(root, "_threads")
  end

  defp record_path(id),
    do: Path.join(root(), Base.url_encode64(to_string(id), padding: false) <> ".json")

  defp patch_path(id, patch),
    do:
      record_path(id) <>
        "." <> Base.encode16(:crypto.hash(:sha256, patch), case: :lower) <> ".patch"

  defp read(id), do: with({:ok, bytes} <- File.read(record_path(id)), do: JSON.decode(bytes))

  defp records do
    Path.wildcard(Path.join(root(), "*.json"))
    |> Enum.flat_map(fn path ->
      with {:ok, bytes} <- File.read(path),
           {:ok, r} <- JSON.decode(bytes),
           do: [r],
           else: (_ -> [])
    end)
  end

  defp save(r) do
    path = record_path(r["id"])

    with :ok <- File.mkdir_p(root()),
         :ok <- File.write(path <> ".tmp", JSON.encode!(r)),
         :ok <- File.chmod(path <> ".tmp", 0o600),
         :ok <- File.rename(path <> ".tmp", path),
         do: :ok
  end
end
