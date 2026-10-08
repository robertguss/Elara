defmodule Elara.Threads do
  @moduledoc "Durable delegation ownership. Sessions, not coordinators, own child execution."
  use GenServer
  alias Elara.Session.Store

  @default_limit 4
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Start a child of `parent`. Options: `coding` (a worktree), `history` (the
  parent's transcript), `pause_inputs` (the assignment stays pending until
  `Elara.resume_inputs/1`) and `provider` (replaces the parent's provider; same
  module only, with the parent's visibility settings). The model-facing tool
  passes only `coding` and `history`.
  """
  def start_child(parent, assignment, opts \\ []),
    do: GenServer.call(__MODULE__, {:start, parent, assignment, opts}, :infinity)

  def list(parent), do: GenServer.call(__MODULE__, {:list, parent})
  def resume(id, opts \\ []), do: GenServer.call(__MODULE__, {:resume, id, opts}, :infinity)
  def review_child(parent, id), do: GenServer.call(__MODULE__, {:review, parent, id}, :infinity)

  def acknowledge_child(parent, id, expected_digest, expected_call_ids),
    do:
      GenServer.call(
        __MODULE__,
        {:acknowledge, parent, id, expected_digest, expected_call_ids},
        :infinity
      )

  def integrate(parent, id), do: GenServer.call(__MODULE__, {:integrate, parent, id}, :infinity)
  def cleanup(parent, id), do: GenServer.call(__MODULE__, {:cleanup, parent, id}, :infinity)
  def stop_subtree(parent), do: GenServer.call(__MODULE__, {:stop, parent})
  def managed?(id), do: File.exists?(record_path(id))

  @doc "Canonical direct relationships; text and supplied workspace paths never grant access."
  def related?(a, b) when is_binary(a) and is_binary(b) do
    Enum.any?(Elara.Session.Handoff.lineage(a), fn source_a ->
      Enum.any?(Elara.Session.Handoff.lineage(b), fn source_b ->
        source_a == source_b or match?({:ok, %{"parent_id" => ^source_a}}, read(source_b)) or
          match?({:ok, %{"parent_id" => ^source_b}}, read(source_a))
      end)
    end)
  end

  def related?(_, _), do: false
  def record(id), do: read(id)
  def all_records, do: records()

  def navigation(id) do
    children = list(id).children

    children =
      case Elara.Session.Handoff.store(id) do
        {:ok, %{context: %{"source" => source}, cwd: cwd}} ->
          [
            %{
              "id" => source,
              "assignment" => "↑ Handoff source",
              "state" => "source",
              "cwd" => cwd
            }
            | children
          ]

        _ ->
          children
      end

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

  @doc "Running children allowed per VM: `:elara, :thread_limit`, default 4."
  def limit do
    case Application.get_env(:elara, :thread_limit, @default_limit) do
      limit when is_integer(limit) and limit > 0 ->
        limit

      other ->
        raise ArgumentError, "thread_limit must be a positive integer, got #{inspect(other)}"
    end
  end

  @doc false
  def acquire_slot(id) do
    not Enum.any?(Elara.Session.Handoff.lineage(id), &managed?/1) or
      Registry.keys(Elara.ThreadSlots, self()) != [] or
      Enum.any?(1..limit(), fn slot ->
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

    if status do
      original = Enum.find(Elara.Session.Handoff.lineage(id), &managed?/1)

      if original && Process.whereis(__MODULE__),
        do: send(Process.whereis(__MODULE__), {:lifecycle, original, status})
    end

    :ok
  end

  def tool do
    %Elara.Tool{
      name: "start_child",
      description:
        "Start independent persistent child work. #{limit()} running children maximum. Coding uses a durable clean-HEAD worktree; research shares cwd with read-only tools. Selected assignment/context only by default. No automatic integration or cleanup. Embedded VM exit interrupts children.",
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
       limit: limit(),
       children:
         Enum.filter(records(), &(&1["parent_id"] in Elara.Session.Handoff.lineage(parent)))
         |> Enum.map(&view/1)
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
             config.allowed_capabilities == :all or "delegate" in config.allowed_capabilities,
           {:ok, provider} <- child_provider(config.provider, Keyword.get(opts, :provider)) do
        create(parent, assignment, %{config | provider: provider}, opts)
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

  def handle_call({:review, parent, id}, _from, state) do
    result =
      with {:ok, r} <- owned_original(parent, id),
           true <- r["coding"] and r["state"] != "cleaned" do
        child_workspace_operation(id, fn evidence -> review_patch(r, evidence) end)
      else
        false -> {:error, :not_reviewable}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call(
        {:acknowledge, parent, id, expected_digest, expected_call_ids},
        _from,
        state
      ) do
    result =
      with {:ok, r} <- owned_original(parent, id),
           true <- r["coding"] and r["state"] != "cleaned",
           true <- valid_digest?(expected_digest),
           true <-
             is_list(expected_call_ids) and
               Enum.all?(expected_call_ids, &(is_binary(&1) and String.valid?(&1))) do
        child_workspace_operation(id, fn evidence ->
          acknowledge_patch(r, evidence, expected_digest, expected_call_ids)
        end)
      else
        false -> {:error, :invalid_acknowledgement}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:integrate, parent, id}, _from, state) do
    result =
      with {:ok, r} <- owned(parent, id),
           true <-
             r["coding"] and r["state"] != "cleaned" and r["integration_state"] != "integrating" do
        case Map.fetch(r, "acknowledgements") do
          {:ok, receipts} when is_list(receipts) and receipts != [] ->
            with {:ok, _} <- owned_original(parent, id),
                 :ok <- live_original(parent) do
              child_workspace_operation(id, fn evidence ->
                live_workspace_operation(parent, fn -> integrate_acknowledged(r, evidence) end)
              end)
            end

          :error ->
            with :ok <- reconciled(id) do
              workspace_operation(id, fn ->
                workspace_operation(parent, fn -> integrate_patch(r) end)
              end)
            end

          {:ok, []} ->
            with :ok <- reconciled(id) do
              workspace_operation(id, fn ->
                workspace_operation(parent, fn -> integrate_patch(r) end)
              end)
            end

          {:ok, _} ->
            {:error, :acknowledgement_stale_or_malformed}
        end
      else
        false -> {:error, :not_integrable}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:cleanup, parent, id}, _from, state) do
    result =
      with {:ok, r} <- owned(parent, id),
           true <- r["coding"] and r["integration_state"] == "integrated" do
        case Map.fetch(r, "acknowledgements") do
          {:ok, receipts} when is_list(receipts) and receipts != [] ->
            with {:ok, _} <- owned_original(parent, id),
                 :ok <- live_original(parent) do
              child_workspace_operation(
                id,
                fn evidence -> cleanup_acknowledged(r, evidence) end,
                true
              )
            end

          :error ->
            with :ok <- reconciled(id) do
              workspace_operation(id, fn -> cleanup_worktree(r) end, true)
            end

          {:ok, []} ->
            with :ok <- reconciled(id) do
              workspace_operation(id, fn -> cleanup_worktree(r) end, true)
            end

          {:ok, _} ->
            {:error, :acknowledgement_stale_or_malformed}
        end
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

  defp review_patch(r, evidence) do
    with [_ | _] <- evidence.occurrences,
         {:ok, capture} <- capture_patch(r),
         true <- capture.patch != "",
         path = review_path(r["id"], capture.digest),
         :ok <- write_once(path, capture.patch) do
      {:ok,
       %{
         child: r["id"],
         base: r["base_revision"],
         tree: capture.tree,
         digest: capture.digest,
         path: path,
         call_ids: Enum.map(evidence.occurrences, & &1.call_id),
         occurrences: evidence.occurrences
       }}
    else
      [] -> {:error, :nothing_to_acknowledge}
      false -> {:error, :not_integrable}
      error -> error
    end
  end

  defp acknowledge_patch(
         %{"acknowledgements" => receipts},
         _evidence,
         _expected_digest,
         _expected_call_ids
       )
       when not is_nil(receipts) and not is_list(receipts),
       do: {:error, :acknowledgement_stale_or_malformed}

  defp acknowledge_patch(r, evidence, expected_digest, expected_call_ids) do
    with [_ | _] <- evidence.occurrences,
         true <-
           Enum.sort(expected_call_ids) == Enum.sort(Enum.map(evidence.occurrences, & &1.call_id)),
         {:ok, capture} <- capture_patch(r),
         true <- capture.patch != "" and capture.digest == expected_digest do
      receipt = %{
        "version" => 1,
        "child" => r["id"],
        "base" => r["base_revision"],
        "digest" => capture.digest,
        "occurrences" => Enum.map(evidence.occurrences, &persist_occurrence/1),
        "timestamp" => System.system_time(:millisecond)
      }

      with :ok <- save(Map.put(r, "acknowledgements", (r["acknowledgements"] || []) ++ [receipt])) do
        {:ok, %{digest: capture.digest, occurrences: evidence.occurrences}}
      end
    else
      [] ->
        {:error, :nothing_to_acknowledge}

      false ->
        if Enum.sort(expected_call_ids) == Enum.sort(Enum.map(evidence.occurrences, & &1.call_id)),
          do: {:error, :reviewed_patch_changed},
          else: {:error, :uncertainty_occurrences_changed}

      error ->
        error
    end
  end

  defp integrate_acknowledged(r, evidence) do
    with {:ok, capture} <- capture_patch(r),
         :ok <- matching_receipt(r, evidence, capture) do
      integrate_patch(r, capture, :fresh)
    end
  end

  defp cleanup_acknowledged(r, evidence) do
    with {:ok, capture} <- capture_patch(r),
         :ok <- matching_receipt(r, evidence, capture) do
      cleanup_worktree(r, capture.tree)
    end
  end

  defp matching_receipt(r, evidence, capture) do
    receipt = List.last(r["acknowledgements"] || [])

    expected = Enum.map(evidence.occurrences, &persist_occurrence/1)

    if is_map(receipt) and map_size(receipt) == 6 and receipt["version"] == 1 and
         receipt["child"] == r["id"] and receipt["base"] == r["base_revision"] and
         receipt["digest"] == capture.digest and receipt["occurrences"] == expected and
         is_integer(receipt["timestamp"]),
       do: :ok,
       else: {:error, :acknowledgement_stale_or_malformed}
  end

  defp persist_occurrence(occurrence) do
    %{
      "session_id" => occurrence.session_id,
      "entry_id" => occurrence.entry_id,
      "call_id" => occurrence.call_id,
      "tool" => occurrence.tool,
      "text" => occurrence.text
    }
  end

  defp integrate_patch(r),
    do: with({:ok, capture} <- capture_patch(r), do: integrate_patch(r, capture, :retained))

  defp integrate_patch(r, capture, artifact) do
    id = r["id"]

    with {:ok, ""} <- git(r["parent_cwd"], ["status", "--porcelain", "--untracked-files=all"]),
         {:ok, revision} <- git(r["parent_cwd"], ["rev-parse", "HEAD"]),
         tree = capture.tree,
         patch = capture.patch,
         true <- patch != "",
         path = application_path(id, patch, artifact),
         integration = %{
           "patch" => path,
           "tree" => tree,
           "parent_revision" => String.trim(revision)
         },
         :ok <- write_application(path, patch, artifact),
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

  defp cleanup_worktree(r),
    do: with({:ok, tree} <- capture_tree(r), do: cleanup_worktree(r, tree))

  defp cleanup_worktree(r, tree) do
    with :ok <- :ok,
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

  defp child_provider(inherited, nil), do: {:ok, inherited}

  defp child_provider({module, _} = inherited, {module, _} = override),
    do:
      {:ok,
       Elara.Provider.Visibility.configure(
         override,
         Elara.Provider.Visibility.settings(inherited)
       )}

  defp child_provider(_inherited, _override), do: {:error, :provider_mismatch}

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
                  t.name in ["read", "skill"] or
                    t.run in [{Elara.Threads.Communication, :run}, {Elara.Completion, :run}]
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
            provider_retry: config.provider_retry,
            tool_timeout_ms: config.tool_timeout_ms,
            context_limit: config.context_limit
          ]

      history = if Keyword.get(opts, :history, false), do: Elara.transcript(parent), else: []
      paused = Keyword.get(opts, :pause_inputs, false)
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
             :ok <- launch(record, paused) do
          {:ok, view(Map.put(record, "state", "running"))}
        end
      end
    end
  end

  # A managed child always starts paused (`canonical_options/2`); launch resumes it
  # unless the caller holds the assignment pending with `pause_inputs: true`.
  defp launch(record, paused) do
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
         do: if(paused, do: :ok, else: Elara.resume_inputs(record["id"]))
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
    limit = limit()

    cond do
      Registry.count(Elara.ThreadSlots) < limit -> :ok
      limit == @default_limit -> {:error, :child_concurrency_limit_4}
      true -> {:error, {:child_concurrency_limit, limit}}
    end
  end

  defp depth(id) do
    original = Enum.find(Elara.Session.Handoff.lineage(id), &managed?/1) || id

    case read(original) do
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

  defp child_workspace_operation(id, operation, retire? \\ false) do
    case Elara.session_pid(id) do
      {:ok, pid} ->
        GenServer.call(pid, {:child_workspace_operation, id, operation, retire?}, :infinity)

      _ ->
        {:error, :resume_child_before_workspace_operation}
    end
  end

  defp live_workspace_operation(id, operation) do
    case Elara.session_pid(id) do
      {:ok, pid} ->
        GenServer.call(pid, {:acknowledged_parent_workspace_operation, operation}, :infinity)

      _ ->
        {:error, :resume_parent_before_workspace_operation}
    end
  end

  defp live_original(id) do
    with ^id <- Elara.Session.Handoff.owner(id),
         {:ok, _} <- Elara.session_pid(id),
         do: :ok,
         else: (_ -> {:error, :handoff_context_rejected})
  end

  defp descendants(parent, records) do
    Enum.flat_map(
      Enum.filter(records, &(&1["parent_id"] in Elara.Session.Handoff.lineage(parent))),
      fn r ->
        [r["id"] | descendants(r["id"], records)]
      end
    )
  end

  defp owned(parent, id) do
    with {:ok, r} <- read(id) do
      if r["parent_id"] in Elara.Session.Handoff.lineage(parent),
        do: {:ok, r},
        else: {:error, :not_child_of_parent}
    end
  end

  defp owned_original(parent, id) do
    with {:ok, r} <- read(id),
         true <- r["parent_id"] == parent,
         ^id <- Elara.Session.Handoff.logical_id(id),
         ^parent <- Elara.Session.Handoff.owner(parent) do
      {:ok, r}
    else
      false -> {:error, :not_child_of_parent}
      _ -> {:error, :handoff_context_rejected}
    end
  end

  defp view(r) do
    r = Map.delete(r, "options")

    case Elara.status(Elara.Session.Handoff.owner(r["id"])) do
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

  defp capture_patch(r) do
    with {:ok, tree} <- capture_tree(r),
         {:ok, patch} <- git(r["cwd"], ["diff", "--binary", r["base_revision"], tree]) do
      {:ok,
       %{
         tree: tree,
         patch: patch,
         digest: Base.encode16(:crypto.hash(:sha256, patch), case: :lower)
       }}
    end
  end

  defp valid_digest?(digest),
    do: is_binary(digest) and byte_size(digest) == 64 and digest =~ ~r/\A[0-9a-f]{64}\z/

  defp write_once(path, bytes) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        result = IO.binwrite(file, bytes)
        File.close(file)

        with :ok <- result,
             :ok <- File.chmod(path, 0o600),
             do: :ok

      {:error, :eexist} ->
        case File.read(path) do
          {:ok, ^bytes} -> :ok
          {:ok, _} -> {:error, :review_artifact_conflict}
          error -> error
        end

      error ->
        error
    end
  end

  defp write_application(path, bytes, :fresh) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        result = IO.binwrite(file, bytes)
        File.close(file)
        result

      error ->
        error
    end
  end

  defp write_application(path, bytes, :retained), do: File.write(path, bytes)

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

  defp application_path(id, patch, :retained), do: patch_path(id, patch)

  defp application_path(id, _patch, :fresh),
    do:
      record_path(id) <>
        ".apply." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false) <> ".patch"

  defp review_path(id, digest), do: record_path(id) <> ".review." <> digest <> ".patch"

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
