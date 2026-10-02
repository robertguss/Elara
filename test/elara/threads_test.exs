defmodule Elara.ThreadsTest do
  use ExUnit.Case, async: false
  alias Elara.{Message, Threads}
  alias Elara.Message.ToolCall

  setup do
    root = Path.join(System.tmp_dir!(), "elara-threads-#{System.unique_integer([:positive])}")
    cwd = Path.join(root, "project")
    File.mkdir_p!(cwd)
    previous = Application.get_env(:elara, :sessions_root)
    Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))
    git(cwd, ["init", "-q"])
    git(cwd, ["config", "user.email", "test@example.invalid"])
    git(cwd, ["config", "user.name", "Test"])
    git(cwd, ["config", "commit.gpgsign", "false"])
    File.write!(Path.join(cwd, "file.txt"), "base\n")
    File.write!(Path.join(cwd, "AGENTS.md"), "Child project instructions marker")
    skill = Path.join(cwd, ".agents/skills/local-check")
    File.mkdir_p!(skill)

    File.write!(
      Path.join(skill, "SKILL.md"),
      "---\nname: local-check\ndescription: Test child skill discovery\n---\nChild skill body marker\n"
    )

    git(cwd, ["add", "."])
    git(cwd, ["commit", "-qm", "base"])

    on_exit(fn ->
      for session <- Elara.live_sessions(), String.starts_with?(session.cwd, root) do
        stop(session.id)
      end

      Application.put_env(:elara, :sessions_root, previous)
      File.rm_rf!(root)
    end)

    %{cwd: cwd, root: root}
  end

  defp git(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end

  defp answer(text, calls \\ []) do
    {:ok, a} = Message.assistant(text, calls)
    {:ok, a}
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp parent(cwd, replies, opts \\ []) do
    provider = script(replies)
    # These lifecycle fixtures script child turns only, not automatic report responses.
    {:ok, id} = Elara.start_session([cwd: cwd, provider: provider, pause_inputs: true] ++ opts)
    {id, provider}
  end

  defp stop(id) do
    case Elara.session_pid(id) do
      {:ok, pid} -> GenServer.stop(pid)
      _ -> :ok
    end
  end

  defp await(fun, tries \\ 200)
  defp await(_, 0), do: flunk("condition did not converge")

  defp await(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await(fun, tries - 1)
        )
  end

  defp finished(parent, id) do
    await(fn ->
      Enum.any?(
        Threads.list(parent).children,
        &(&1["id"] == id and &1["state"] in ["completed", "failed", "interrupted"])
      )
    end)
  end

  defp retain_uncertainties(child, provider, uncertainties) do
    stop(child["id"])
    {:ok, store} = Elara.Session.Store.open(child["session_path"])
    parent_id = store.entries |> List.first() |> Map.fetch!(:id)

    entries =
      Enum.map(uncertainties, fn {entry_id, call_id, tool, text} ->
        %Elara.Session.Store.Entry{
          id: entry_id,
          parent_id: parent_id,
          timestamp: System.system_time(:millisecond),
          message: %Message.ToolResult{
            call_id: call_id,
            name: tool,
            outcome: {:indeterminate, text}
          }
        }
      end)

    # Keep the original leaf: these durable occurrences are deliberately off-branch.
    {:ok, _} = Elara.Session.Store.save(%{store | entries: store.entries ++ entries})
    assert {:ok, child_id} = Threads.resume(child["id"], provider: provider)
    assert child_id == child["id"]
  end

  defp record_path(root, id) do
    Enum.find(Path.wildcard(Path.join(root, "sessions/_threads/*.json")), fn path ->
      JSON.decode!(File.read!(path))["id"] == id
    end)
  end

  test "coding worktree excludes dirty parent; failure and parent exit leave sibling running", %{
    cwd: cwd
  } do
    replies = [
      answer(nil, [
        %ToolCall{
          id: "write-child",
          name: "write",
          args: {:ok, %{"path" => "file.txt", "content" => "child\n"}}
        }
      ]),
      {:stream, [{:sleep, 500}], answer("coding finished")},
      {:error, %Elara.Provider.Error{kind: :bad_response, message: "sibling failure"}}
    ]

    {parent, _} = parent(cwd, replies)
    File.write!(Path.join(cwd, "parent-only.txt"), "uncommitted")
    {:ok, coding} = Threads.start_child(parent, "Implement isolated change", coding: true)
    assert coding["cwd"] != cwd
    refute File.exists?(Path.join(coding["cwd"], "parent-only.txt"))
    assert coding["base_revision"] == git(cwd, ["rev-parse", "HEAD"])
    await(fn -> File.read!(Path.join(coding["cwd"], "file.txt")) == "child\n" end)
    {:ok, research} = Threads.start_child(parent, "Research failure")
    finished(parent, research["id"])
    assert Elara.status(coding["id"]).phase != :idle
    assert Elara.child_config(research["id"]).allowed_capabilities == ["filesystem:read"]

    assert Enum.map(Elara.child_config(research["id"]).tools, & &1.name) |> Enum.sort() == [
             "read",
             "skill",
             "thread_read",
             "thread_send",
             "thread_status",
             "thread_wait"
           ]

    stop(parent)
    finished(parent, coding["id"])
    assert List.last(Elara.transcript(coding["id"])).text == "coding finished"
    assert File.read!(Path.join(cwd, "file.txt")) == "base\n"
    assert File.read!(Path.join(cwd, "parent-only.txt")) == "uncommitted"
    assert {:error, :unintegrated_work_preserved} = Threads.cleanup(parent, coding["id"])
  end

  test "recorded integration detects conflict, preserves dirty parent, and cleanup rejects later changes",
       %{cwd: cwd} do
    {parent, _} = parent(cwd, [answer("done")])
    {:ok, child} = Threads.start_child(parent, "coding", coding: true)
    id = child["id"]
    finished(parent, id)
    File.write!(Path.join(child["cwd"], "file.txt"), "child\n")
    File.write!(Path.join(cwd, "file.txt"), "owner dirty\n")
    assert {:error, :parent_has_uncommitted_work} = Threads.integrate(parent, id)
    assert File.read!(Path.join(cwd, "file.txt")) == "owner dirty\n"
    git(cwd, ["add", "."])
    git(cwd, ["commit", "-qm", "conflicting owner work"])
    assert {:error, {:git, _}} = Threads.integrate(parent, id)
    # Restore only this test fixture's file, as a new parent commit.
    File.write!(Path.join(cwd, "file.txt"), "base\n")
    git(cwd, ["add", "."])
    git(cwd, ["commit", "-qm", "restore fixture"])
    assert {:ok, %{patch: patch}} = Threads.integrate(parent, id)
    assert File.read!(patch) =~ "child"
    original_patch = File.read!(patch)
    assert File.read!(Path.join(cwd, "file.txt")) == "child\n"
    File.write!(Path.join(child["cwd"], "later.txt"), "must survive")
    assert {:error, :unintegrated_work_preserved} = Threads.cleanup(parent, id)
    git(cwd, ["commit", "-qm", "parent accepts first result"])
    assert {:error, {:git, _}} = Threads.integrate(parent, id)
    assert File.read!(patch) == original_patch
    File.rm!(Path.join(child["cwd"], "later.txt"))
    assert {:error, {:git, _}} = Threads.cleanup(parent, id)
    git(child["cwd"], ["add", "."])
    git(child["cwd"], ["commit", "-qm", "preserve integrated child commit"])
    assert :ok = Threads.cleanup(parent, id)
    refute File.exists?(child["cwd"])
    assert File.exists?(child["session_path"])
    assert {:error, :workspace_cleaned} = Threads.resume(id)
  end

  test "restart pauses child inbox and explicit resume preserves identity, tools, context and workspace",
       %{cwd: cwd} do
    {parent, provider} =
      parent(cwd, [
        {:stream, [{:sleep, 10_000}], answer("not replayed")},
        answer("explicitly resumed")
      ])

    {:ok, child} = Threads.start_child(parent, "selected assignment", coding: true)
    id = child["id"]
    await(fn -> Elara.transcript(id) != [] end)
    assert [%Message.User{text: "selected assignment"}] = Elara.transcript(id)
    assert Elara.status(id).instructions |> inspect() =~ "Child project instructions marker"
    skills = Elara.status(id).skills

    assert skills.skills["local-check"].path ==
             Path.join(child["cwd"], ".agents/skills/local-check/SKILL.md")

    assert {:ok, body} = Elara.Skills.load(skills, "local-check")
    assert body =~ "Child skill body marker"

    {:ok, _} =
      Elara.submit_input(id, %{
        id: "pending",
        sender_id: parent,
        kind: :normal,
        user: Message.user("queued, do not replay")
      })

    File.write!(Path.join(child["cwd"], "saved.txt"), "survives")
    stop(id)
    stop(parent)
    :ok = Supervisor.terminate_child(Elara.Supervisor, Elara.Threads)
    {:ok, _} = Supervisor.restart_child(Elara.Supervisor, Elara.Threads)
    assert {:ok, ^id} = Threads.resume(id, provider: provider)
    assert Elara.cwd(id) == child["cwd"]
    assert Elara.snapshot(id).snapshot["inbox"]["paused"]
    assert {:ok, %{state: :queued}} = Elara.input_status(id, "pending")
    assert File.read!(Path.join(child["cwd"], "saved.txt")) == "survives"
    assert {:ok, "explicitly resumed"} = Elara.ask(id, "continue explicitly")

    refute Enum.any?(
             Elara.transcript(id),
             &match?(%Message.User{text: "queued, do not replay"}, &1)
           )
  end

  test "history is opt-in and explicit capabilities cannot be widened", %{cwd: cwd} do
    {parent, _} = parent(cwd, [answer("parent answer"), answer("fresh"), answer("forked")])
    {:ok, _} = Elara.ask(parent, "parent context")
    {:ok, fresh} = Threads.start_child(parent, "fresh assignment")
    finished(parent, fresh["id"])
    assert [%Message.User{text: "fresh assignment"}, _] = Elara.transcript(fresh["id"])
    {:ok, forked} = Threads.start_child(parent, "forked assignment", history: true)
    finished(parent, forked["id"])

    assert [%Message.User{text: "parent context"}, _, %Message.User{text: "forked assignment"}, _] =
             Elara.transcript(forked["id"])

    {restricted, _} = parent(cwd, [], allowed_capabilities: ["filesystem:read"])

    assert {:error, :invalid_assignment_or_delegation_restricted} =
             Threads.start_child(restricted, "cannot escape", coding: true)
  end

  test "four global slots include resumed turns and explicit subtree stop does not delete work",
       %{cwd: cwd} do
    {parent, _} =
      parent(cwd, [
        answer("initial") | List.duplicate({:stream, [{:sleep, 10_000}], answer("late")}, 4)
      ])

    {:ok, idle_child} = Threads.start_child(parent, "already completed child")
    finished(parent, idle_child["id"])

    children =
      for n <- 1..4 do
        {:ok, child} = Threads.start_child(parent, "child #{n}")
        child
      end

    assert {:error, :child_concurrency_limit_4} = Threads.start_child(parent, "fifth")
    assert Threads.list(parent).limit == 4
    assert Threads.tool().description =~ "4 running children maximum."

    assert {:error, {:provider_error, %Elara.Provider.Error{kind: :resource_limit}}} =
             Elara.ask(idle_child["id"], "resumed turn also needs a slot")

    Elara.interrupt(parent)
    assert Enum.all?(children, &(Elara.status(&1["id"]).phase != :idle))
    assert {:ok, %{requested: ids}} = Threads.stop_subtree(parent)
    assert length(ids) == 6
    Enum.each(children, &finished(parent, &1["id"]))
    assert Enum.all?(children, &File.exists?(&1["session_path"]))
  end

  defp with_thread_limit(limit) do
    previous = Application.fetch_env(:elara, :thread_limit)
    Application.put_env(:elara, :thread_limit, limit)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:elara, :thread_limit, value)
        :error -> Application.delete_env(:elara, :thread_limit)
      end
    end)
  end

  # Each request waits for the test's answer, so a turn holds its slot for exactly
  # as long as the test decides.
  defmodule GatedProvider do
    def chat(test, _request) do
      send(test, {:provider_request, self()})

      receive do
        {:answer, text} ->
          {:ok, message} = Elara.Message.assistant(text, [])
          {:ok, message, test}
      end
    end
  end

  defp next_request do
    assert_receive {:provider_request, task}, 5_000
    task
  end

  test "a configured thread limit governs admission, slot acquisition and the reported limit",
       %{cwd: cwd} do
    with_thread_limit(1)

    {:ok, parent} =
      Elara.start_session(cwd: cwd, provider: {GatedProvider, self()}, pause_inputs: true)

    {:ok, idle_child} = Threads.start_child(parent, "already completed child")
    send(next_request(), {:answer, "idle"})
    finished(parent, idle_child["id"])

    # The busy child's request proves it acquired the only slot before dispatch.
    {:ok, _busy} = Threads.start_child(parent, "holds the only slot")
    busy = next_request()

    assert {:error, {:child_concurrency_limit, 1}} = Threads.start_child(parent, "second")
    assert Threads.list(parent).limit == 1
    assert Threads.tool().description =~ "1 running children maximum."

    assert {:error,
            {:provider_error, %Elara.Provider.Error{kind: :resource_limit, message: message}}} =
             Elara.ask(idle_child["id"], "a resumed turn needs a slot")

    assert message =~ "Child concurrency limit 1 reached"

    Application.put_env(:elara, :thread_limit, 2)
    assert {:ok, _} = Threads.start_child(parent, "admitted at two")
    send(next_request(), {:answer, "at two"})
    send(busy, {:answer, "released"})
  end

  test "an invalid thread limit raises instead of admitting" do
    with_thread_limit(0)

    for invalid <- [0, -1, "4", 1.5, nil] do
      Application.put_env(:elara, :thread_limit, invalid)
      assert_raise ArgumentError, fn -> Threads.limit() end
    end
  end

  defp context_limit(id), do: Elara.snapshot(id).snapshot["inbox"]["context"]["limit"]

  test "children inherit the parent's context limit, and keep it on resume", %{cwd: cwd} do
    {parent, provider} = parent(cwd, [answer("child done")], context_limit: 1_000_000)
    {:ok, child} = Threads.start_child(parent, "inherit the limit", coding: true)
    id = child["id"]
    finished(parent, id)
    assert context_limit(id) == 1_000_000

    stop(id)
    assert {:ok, ^id} = Threads.resume(id, provider: provider)
    assert context_limit(id) == 1_000_000
  end

  test "a paused child holds its assignment unconsumed until its inputs resume", %{cwd: cwd} do
    {parent, {_, agent}} = parent(cwd, [answer("assignment answered")])

    {:ok, child} =
      Threads.start_child(parent, "held assignment", coding: true, pause_inputs: true)

    id = child["id"]
    # Give a wrongly unpaused child time to run its assignment.
    Process.sleep(200)
    assert Elara.transcript(id) == []
    assert Elara.snapshot(id).snapshot["inbox"]["paused"]
    assert {:ok, %{state: state}} = Elara.input_status(id, "assignment")
    assert state in [:accepted, :queued]
    assert length(Agent.get(agent, & &1)) == 1

    :ok = Elara.resume_inputs(id)
    finished(parent, id)

    assert [
             %Message.User{text: "held assignment"},
             %Message.Assistant{text: "assignment answered"}
           ] = Elara.transcript(id)
  end

  test "a provider override answers the child; another module is refused before any workspace",
       %{cwd: cwd, root: root} do
    {parent, {_, parent_agent}} = parent(cwd, [answer("parent reply")])
    own = script([answer("override reply")])

    {:ok, child} = Threads.start_child(parent, "use my provider", coding: true, provider: own)
    finished(parent, child["id"])
    assert List.last(Elara.transcript(child["id"])).text == "override reply"
    assert length(Agent.get(parent_agent, & &1)) == 1

    records = Path.wildcard(Path.join(root, "sessions/_threads/*.json"))
    workspaces = Path.wildcard(Path.join(root, "sessions/_threads/workspaces/*"))
    other = Elara.Provider.Simulated.new(seed: 1, id: "other")

    assert {:error, :provider_mismatch} =
             Threads.start_child(parent, "wrong module", coding: true, provider: other)

    assert Path.wildcard(Path.join(root, "sessions/_threads/*.json")) == records
    assert Path.wildcard(Path.join(root, "sessions/_threads/workspaces/*")) == workspaces
  end

  # Expired Codex-sourced tokens fail before any refresh or request, and the
  # closed loopback port is a second guard, so this never reaches the network.
  defp offline_codex(model, effort) do
    tokens = %Elara.Auth.OpenAICodex{
      access_token: "fake-access",
      account_id: "fake-account",
      expires_at: System.system_time(:second) - 3_600,
      source: :codex
    }

    {Elara.Provider.OpenAICodex,
     Elara.Provider.OpenAICodex.new(tokens,
       model: model,
       effort: effort,
       base_url: "http://127.0.0.1:1/backend-api"
     )}
  end

  test "a provider override keeps the parent's visibility settings", %{cwd: cwd} do
    {:ok, parent} =
      Elara.start_session(
        cwd: cwd,
        provider: offline_codex("parent-model", "high"),
        pause_inputs: true
      )

    {:ok, child} =
      Threads.start_child(parent, "keep settings",
        coding: true,
        pause_inputs: true,
        provider: offline_codex("override-model", "low")
      )

    assert child["model"] == "parent-model"
    assert child["settings"] == %{"model" => "parent-model", "effort" => "high"}
  end

  test "model-callable start uses actual owning identity and does not block parent's turn", %{
    cwd: cwd
  } do
    call = %ToolCall{
      id: "delegate-call",
      name: "start_child",
      args: {:ok, %{"assignment" => "model child", "coding" => true}}
    }

    {parent, _} =
      parent(cwd, [answer(nil, [call]), answer("one result"), answer("another result")])

    assert {:ok, _} = Elara.ask(parent, "delegate selected task")
    assert %{children: [child]} = Threads.list(parent)
    assert child["parent_id"] == parent
    finished(parent, child["id"])

    assert Enum.any?(
             Elara.transcript(parent),
             &match?(%Message.ToolResult{name: "start_child", outcome: {:ok, _}}, &1)
           )

    assert {:ok, store} = Elara.Session.Store.open(child["session_path"])
    assert store.parent_session == parent
  end

  defp socket(port) do
    {:ok, s} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])
    s
  end

  defp request(socket, request) do
    :ok = :gen_tcp.send(socket, Elara.Protocol.encode(Map.put(request, "version", 2)))
    response(socket)
  end

  defp response(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    {:ok, frame} = Elara.Protocol.decode(line)
    if frame["type"] == "patch", do: response(socket), else: frame
  end

  test "server rejects observer mutations and opens saved research from parent cwd with original restrictions",
       %{cwd: cwd} do
    {parent, provider} = parent(cwd, [answer("research complete")])
    {:ok, server} = Elara.Server.start_link(port: 0, provider: provider, lifetime: :long_lived)
    owner = socket(Elara.Server.port(server))
    observer = socket(Elara.Server.port(server))

    assert %{"type" => "attached"} =
             request(owner, %{"command" => "attach", "session_id" => parent})

    assert %{"type" => "attached"} =
             request(observer, %{
               "command" => "attach",
               "session_id" => parent,
               "mode" => "observe"
             })

    for command <- [
          "child_start",
          "child_review",
          "child_acknowledge",
          "child_integrate",
          "child_cleanup",
          "child_stop_subtree"
        ] do
      assert %{"type" => "session_error"} =
               request(observer, %{"command" => command, "assignment" => "forbidden"})
    end

    assert %{"type" => "child_result", "result" => %{"id" => id}} =
             request(owner, %{
               "command" => "child_start",
               "assignment" => "inspect shared checkout"
             })

    finished(parent, id)

    assert %{"child_limit" => 4, "sessions" => [%{"id" => ^id, "tools" => tools}]} =
             request(observer, %{"command" => "child_list"})

    assert Enum.sort(tools) == ~w(read skill thread_read thread_send thread_status thread_wait)

    assert %{
             "type" => "session_error",
             "error" => "managed_child_use_cleanup_transcript_retained"
           } = request(owner, %{"command" => "session_delete", "session_id" => id})

    stop(id)
    child_socket = socket(Elara.Server.port(server))

    assert %{"type" => "attached", "session_id" => ^id} =
             request(child_socket, %{"command" => "attach", "session_id" => id, "cwd" => cwd})

    assert Elara.child_config(id).allowed_capabilities == ["filesystem:read"]
    for s <- [owner, observer, child_socket], do: :gen_tcp.close(s)
    stop(id)
    {:ok, info} = Elara.Session.Store.find(cwd, id)
    assert {:error, :managed_child_open_independently} = Elara.resume(parent, info.path)

    assert {:ok, ^id} =
             Elara.start_session(
               cwd: cwd,
               provider: provider,
               resume: info.path,
               tools: Elara.Tool.builtins(),
               allowed_capabilities: :all
             )

    assert Elara.child_config(id).allowed_capabilities == ["filesystem:read"]
    assert {:error, :managed_child_use_delegate_history} = Elara.clone_session(id)
    GenServer.stop(server)
  end

  test "an uncertain command in a child blocks integration, so cleanup cannot proceed", %{
    cwd: cwd
  } do
    # `yes` is killed at the output cap, so the child records an indeterminate
    # result. Integration and cleanup keep refusing it; a later successful turn
    # does not clear the uncertainty (an operator acknowledgement is a follow-up).
    flood = %ToolCall{id: "flood", name: "bash", args: {:ok, %{"command" => "yes"}}}
    {parent, _} = parent(cwd, [answer(nil, [flood]), answer("done")])
    {:ok, child} = Threads.start_child(parent, "coding", coding: true)
    id = child["id"]
    finished(parent, id)

    assert Enum.any?(
             Elara.transcript(id),
             &match?(
               %Elara.Message.ToolResult{call_id: "flood", outcome: {:indeterminate, _}},
               &1
             )
           )

    File.write!(Path.join(child["cwd"], "file.txt"), "child\n")
    assert {:error, :indeterminate_effects_preserved} = Threads.integrate(parent, id)
    assert File.read!(Path.join(cwd, "file.txt")) == "base\n"

    # Cleanup requires a prior integration, which the uncertainty blocks, so the
    # child's worktree is preserved.
    assert {:error, :unintegrated_work_preserved} = Threads.cleanup(parent, id)
    assert File.exists?(child["cwd"])
  end

  test "review and exact durable acknowledgement integrate retained off-branch uncertainty", %{
    cwd: cwd
  } do
    {parent, provider} = parent(cwd, [answer("done")])
    {:ok, child} = Threads.start_child(parent, "coding", coding: true)
    finished(parent, child["id"])
    File.write!(Path.join(child["cwd"], "file.txt"), "reviewed child bytes\n")

    retain_uncertainties(child, provider, [
      {"uncertain-a", " opaque, id ", "bash", "first may have run"},
      {"uncertain-b", " opaque, id ", "write", "second may have run"}
    ])

    parent_tree = git(cwd, ["write-tree"])
    assert {:ok, review} = Threads.review_child(parent, child["id"])
    assert review.child == child["id"]
    assert review.base == child["base_revision"]
    assert review.call_ids == [" opaque, id ", " opaque, id "]
    assert Enum.map(review.occurrences, & &1.entry_id) == ["uncertain-a", "uncertain-b"]
    assert Enum.map(review.occurrences, & &1.tool) == ["bash", "write"]
    assert File.read!(review.path) =~ "reviewed child bytes"

    assert review.digest ==
             Base.encode16(:crypto.hash(:sha256, File.read!(review.path)), case: :lower)

    assert git(cwd, ["write-tree"]) == parent_tree
    refute Map.has_key?(Threads.record(child["id"]) |> elem(1), "acknowledgements")

    assert {:error, :uncertainty_occurrences_changed} =
             Threads.acknowledge_child(parent, child["id"], review.digest, [" opaque, id "])

    assert {:ok, receipt} =
             Threads.acknowledge_child(
               parent,
               child["id"],
               review.digest,
               [" opaque, id ", " opaque, id "]
             )

    assert receipt.digest == review.digest
    assert Enum.map(receipt.occurrences, & &1.entry_id) == ["uncertain-a", "uncertain-b"]
    assert [persisted] = Threads.record(child["id"]) |> elem(1) |> Map.fetch!("acknowledgements")
    assert persisted["digest"] == review.digest

    # The exported review artifact is evidence only; integration recaptures trusted bytes.
    File.write!(review.path, "malicious replacement")
    assert {:error, :review_artifact_conflict} = Threads.review_child(parent, child["id"])
    assert {:ok, integrated} = Threads.integrate(parent, child["id"])
    assert integrated.tree == review.tree
    refute integrated.patch == review.path
    assert File.read!(Path.join(cwd, "file.txt")) == "reviewed child bytes\n"
    refute File.read!(integrated.patch) == "malicious replacement"

    {:ok, store} = Elara.Session.Store.open(child["session_path"])

    assert Enum.map(Enum.take(store.entries, -2), & &1.message.outcome) == [
             {:indeterminate, "first may have run"},
             {:indeterminate, "second may have run"}
           ]
  end

  test "patch drift and newly retained reused call IDs invalidate acknowledgement", %{
    cwd: cwd
  } do
    {parent, provider} = parent(cwd, [answer("done"), answer("later success")])
    {:ok, child} = Threads.start_child(parent, "coding", coding: true)
    finished(parent, child["id"])
    File.write!(Path.join(child["cwd"], "file.txt"), "reviewed\n")
    retain_uncertainties(child, provider, [{"first-entry", "same", "bash", "first"}])
    assert {:ok, review} = Threads.review_child(parent, child["id"])

    File.write!(Path.join(child["cwd"], "file.txt"), "drifted\n")

    assert {:error, :reviewed_patch_changed} =
             Threads.acknowledge_child(parent, child["id"], review.digest, ["same"])

    File.write!(Path.join(child["cwd"], "file.txt"), "reviewed\n")
    assert {:ok, _} = Threads.acknowledge_child(parent, child["id"], review.digest, ["same"])

    File.write!(Path.join(child["cwd"], "file.txt"), "drifted after ack\n")
    parent_tree = git(cwd, ["write-tree"])
    assert {:error, :acknowledgement_stale_or_malformed} = Threads.integrate(parent, child["id"])
    assert git(cwd, ["write-tree"]) == parent_tree
    File.write!(Path.join(child["cwd"], "file.txt"), "reviewed\n")

    # A successful later turn alone does not invalidate the exact retained occurrences.
    assert {:ok, "later success"} = Elara.ask(child["id"], "continue")
    assert {:ok, _} = Threads.integrate(parent, child["id"])

    # Reuse of the same opaque call ID is still a distinct durable occurrence,
    # and remains visible even though the session leaf is not advanced to it.
    git(cwd, ["reset", "--hard", "HEAD"])
    retain_uncertainties(child, provider, [{"second-entry", "same", "write", "new"}])
    assert {:error, :acknowledgement_stale_or_malformed} = Threads.integrate(parent, child["id"])

    assert {:ok, second_review} = Threads.review_child(parent, child["id"])
    assert second_review.call_ids == ["same", "same"]

    assert {:ok, _} =
             Threads.acknowledge_child(
               parent,
               child["id"],
               second_review.digest,
               ["same", "same"]
             )

    assert [first, second] =
             Threads.record(child["id"]) |> elem(1) |> Map.fetch!("acknowledgements")

    assert length(first["occurrences"]) == 1
    assert length(second["occurrences"]) == 2
  end

  test "newest malformed receipt cannot fall back and live original identity is required", %{
    cwd: cwd,
    root: root
  } do
    {parent, provider} = parent(cwd, [answer("done"), answer("research")])
    {:ok, child} = Threads.start_child(parent, "coding", coding: true)
    finished(parent, child["id"])
    File.write!(Path.join(child["cwd"], "file.txt"), "child\n")
    retain_uncertainties(child, provider, [{"uncertain", "id", "bash", "maybe"}])
    assert {:ok, review} = Threads.review_child(parent, child["id"])
    assert {:ok, _} = Threads.acknowledge_child(parent, child["id"], review.digest, ["id"])

    path = record_path(root, child["id"])
    record = JSON.decode!(File.read!(path))

    File.write!(
      path,
      JSON.encode!(Map.update!(record, "acknowledgements", &(&1 ++ [%{"bad" => true}])))
    )

    assert {:error, :acknowledgement_stale_or_malformed} = Threads.integrate(parent, child["id"])
    assert File.read!(Path.join(cwd, "file.txt")) == "base\n"

    assert {:error, :not_child_of_parent} = Threads.review_child("wrong-parent", child["id"])
    stop(child["id"])

    assert {:error, :resume_child_before_workspace_operation} =
             Threads.acknowledge_child(parent, child["id"], review.digest, ["id"])

    child_id = child["id"]
    assert {:ok, ^child_id} = Threads.resume(child_id, provider: provider)
    {:ok, pid} = Elara.session_pid(child_id)

    assert {:error, :child_workspace_operation_rejected} =
             GenServer.call(
               pid,
               {:child_workspace_operation, child["id"], fn _ -> send(self(), :ran) end, false}
             )

    refute_receive :ran

    shell = :sys.get_state(pid)

    :sys.replace_state(pid, fn state ->
      %{state | store: %{state.store | context: Map.put(state.store.context, "handoff", %{})}}
    end)

    assert {:error, :child_handoff_context_rejected} =
             Threads.review_child(parent, child["id"])

    :sys.replace_state(pid, fn _ -> shell end)
    stop(child["id"])
    {:ok, store} = Elara.Session.Store.open(child["session_path"])

    {:ok, _} =
      Elara.Session.Store.save(%{
        store
        | context: Map.put(store.context, "sources", [%{"id" => "handoff-source"}])
      })

    assert {:ok, ^child_id} = Threads.resume(child_id, provider: provider)
    assert {:error, :handoff_context_rejected} = Threads.review_child(parent, child_id)

    {:ok, research} = Threads.start_child(parent, "research")
    finished(parent, research["id"])
    assert {:error, :not_reviewable} = Threads.review_child(parent, research["id"])
  end

  test "clean child has nothing to acknowledge and empty patch is never reviewable", %{cwd: cwd} do
    {parent, _provider} = parent(cwd, [answer("done")])
    {:ok, child} = Threads.start_child(parent, "coding", coding: true)
    finished(parent, child["id"])
    assert {:error, :nothing_to_acknowledge} = Threads.review_child(parent, child["id"])

    assert {:error, :nothing_to_acknowledge} =
             Threads.acknowledge_child(parent, child["id"], String.duplicate("0", 64), [])
  end

  test "child quiescence barriers and the unchanged strict parent guard each fail closed", %{
    cwd: cwd
  } do
    {parent, provider} = parent(cwd, [answer("done")])
    {:ok, child} = Threads.start_child(parent, "coding", coding: true)
    finished(parent, child["id"])
    File.write!(Path.join(child["cwd"], "file.txt"), "child\n")
    retain_uncertainties(child, provider, [{"uncertain", "id", "bash", "maybe"}])
    {:ok, child_pid} = Elara.session_pid(child["id"])
    child_state = :sys.get_state(child_pid)

    barriers = [
      fn shell -> %{shell | core: %{shell.core | phase: :not_idle_for_test}} end,
      fn shell -> %{shell | tasks: %{make_ref() => :test_task}} end,
      fn shell -> %{shell | effect_recovery_pending: [:test_recovery]} end
    ]

    for barrier <- barriers do
      :sys.replace_state(child_pid, barrier)

      assert {:error, :child_workspace_operation_rejected} =
               Threads.review_child(parent, child["id"])

      :sys.replace_state(child_pid, fn _ -> child_state end)
    end

    assert {:ok, review} = Threads.review_child(parent, child["id"])
    assert {:ok, _} = Threads.acknowledge_child(parent, child["id"], review.digest, ["id"])

    {:ok, parent_pid} = Elara.session_pid(parent)
    parent_state = :sys.get_state(parent_pid)

    :sys.replace_state(parent_pid, fn shell ->
      %{shell | core: %{shell.core | phase: :not_idle_for_test}}
    end)

    assert {:error, :stop_or_reconcile_effects_first} = Threads.integrate(parent, child["id"])
    :sys.replace_state(parent_pid, fn _ -> parent_state end)
    assert {:ok, _} = Threads.integrate(parent, child["id"])
  end

  test "acknowledged cleanup keeps ignored files and removes only the exact integrated tree", %{
    cwd: cwd
  } do
    {parent, provider} = parent(cwd, [answer("done")])
    {:ok, child} = Threads.start_child(parent, "coding", coding: true)
    finished(parent, child["id"])
    File.write!(Path.join(child["cwd"], "file.txt"), "child\n")
    File.write!(Path.join(child["cwd"], ".gitignore"), "ignored.tmp\n")
    retain_uncertainties(child, provider, [{"uncertain", "id", "bash", "maybe"}])
    assert {:ok, review} = Threads.review_child(parent, child["id"])
    assert {:ok, _} = Threads.acknowledge_child(parent, child["id"], review.digest, ["id"])
    assert {:ok, _} = Threads.integrate(parent, child["id"])

    File.write!(Path.join(child["cwd"], "later.txt"), "preserve")
    assert {:error, :acknowledgement_stale_or_malformed} = Threads.cleanup(parent, child["id"])
    assert File.exists?(Path.join(child["cwd"], "later.txt"))
    File.rm!(Path.join(child["cwd"], "later.txt"))

    git(child["cwd"], ["add", "."])
    git(child["cwd"], ["commit", "-qm", "retain integrated tree"])
    File.write!(Path.join(child["cwd"], "ignored.tmp"), "preserve")
    assert {:error, :ignored_files_preserved} = Threads.cleanup(parent, child["id"])
    assert File.exists?(Path.join(child["cwd"], "ignored.tmp"))
    File.rm!(Path.join(child["cwd"], "ignored.tmp"))
    assert :ok = Threads.cleanup(parent, child["id"])
    refute File.exists?(child["cwd"])
  end

  test "acknowledgement survives a fresh VM and still requires explicit child and parent resume",
       %{
         cwd: cwd,
         root: root
       } do
    sessions = Path.join(root, "ack-vm-sessions")
    identity = Path.join(root, "ack-identity.json")

    common = """
    Application.put_env(:elara, :sessions_root, #{inspect(sessions)})
    alias Elara.{Message, Threads}
    alias Elara.Session.Store
    {:ok, reply} = Message.assistant("done", [])
    """

    start_code =
      common <>
        """
        {:ok, agent} = Agent.start_link(fn -> [{:ok, reply}] end)
        provider = {Elara.Provider.Scripted, agent}
        {:ok, parent} = Elara.start_session(cwd: #{inspect(cwd)}, provider: provider, pause_inputs: true)
        {:ok, child} = Threads.start_child(parent, "durable ack", coding: true)
        wait = fn wait ->
          if Enum.any?(Threads.list(parent).children, &(&1["id"] == child["id"] and &1["state"] == "completed")), do: :ok, else: (Process.sleep(10); wait.(wait))
        end
        :ok = wait.(wait)
        File.write!(Path.join(child["cwd"], "file.txt"), "fresh VM ack\\n")
        {:ok, pid} = Elara.session_pid(child["id"])
        GenServer.stop(pid)
        {:ok, store} = Store.open(child["session_path"])
        first = hd(store.entries).id
        occurrence = %Store.Entry{id: "vm-uncertain", parent_id: first, timestamp: 1, message: %Message.ToolResult{call_id: "vm-call", name: "bash", outcome: {:indeterminate, "maybe"}}}
        {:ok, _} = Store.save(%{store | entries: store.entries ++ [occurrence]})
        {:ok, _} = Threads.resume(child["id"], provider: provider)
        {:ok, review} = Threads.review_child(parent, child["id"])
        {:ok, _} = Threads.acknowledge_child(parent, child["id"], review.digest, ["vm-call"])
        File.write!(#{inspect(identity)}, JSON.encode!(%{"parent" => parent, "child" => child}))
        IO.puts("ACK_PERSISTED_BEFORE_VM_EXIT")
        System.halt(0)
        """

    assert {output, 0} =
             System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", start_code],
               stderr_to_stdout: true,
               env: [{"MIX_ENV", "test"}]
             )

    assert output =~ "ACK_PERSISTED_BEFORE_VM_EXIT"

    restart_code =
      common <>
        """
        identity = JSON.decode!(File.read!(#{inspect(identity)}))
        parent = identity["parent"]
        child = identity["child"]
        {:ok, agent} = Agent.start_link(fn -> [] end)
        provider = {Elara.Provider.Scripted, agent}
        {:ok, parent_info} = Store.find(#{inspect(cwd)}, parent)
        {:ok, ^parent} = Elara.start_session(cwd: #{inspect(cwd)}, provider: provider, resume: parent_info.path, pause_inputs: true)
        {:ok, child_id} = Threads.resume(child["id"], provider: provider)
        true = child_id == child["id"]
        {:ok, _} = Threads.integrate(parent, child_id)
        true = File.read!(Path.join(#{inspect(cwd)}, "file.txt")) == "fresh VM ack\\n"
        [_] = Threads.record(child_id) |> elem(1) |> Map.fetch!("acknowledgements")
        IO.puts("ACK_FRESH_VM_INTEGRATION_VERIFIED")
        """

    assert {output, 0} =
             System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", restart_code],
               stderr_to_stdout: true,
               env: [{"MIX_ENV", "test"}]
             )

    assert output =~ "ACK_FRESH_VM_INTEGRATION_VERIFIED"
  end

  test "integration from a nested parent applies repository-root changes rather than skipping them",
       %{cwd: cwd} do
    nested = Path.join(cwd, "nested")
    File.mkdir_p!(nested)
    File.write!(Path.join(nested, "keep.txt"), "nested")
    git(cwd, ["add", "."])
    git(cwd, ["commit", "-qm", "nested invocation"])
    {parent, _} = parent(nested, [answer("done")])

    {:ok, child} =
      Threads.start_child(parent, "change outside invocation directory", coding: true)

    finished(parent, child["id"])
    File.write!(Path.join(child["cwd"], "file.txt"), "root change\n")
    assert {:ok, _} = Threads.integrate(parent, child["id"])
    assert File.read!(Path.join(cwd, "file.txt")) == "root change\n"
    assert child["parent_cwd"] == git(cwd, ["rev-parse", "--show-toplevel"])
    assert child["parent_invocation_cwd"] == nested
  end

  test "a full BEAM exit preserves child identity/worktree and restart never replays assignment",
       %{cwd: cwd, root: root} do
    common = """
    Application.put_env(:elara, :sessions_root, #{inspect(Path.join(root, "vm-sessions"))})
    alias Elara.{Message, Threads}
    {:ok, reply} = Message.assistant("explicit restart answer", [])
    """

    start_code =
      common <>
        """
        {:ok, agent} = Agent.start_link(fn -> [{:stream, [{:sleep, 60_000}], {:ok, reply}}] end)
        {:ok, parent} = Elara.start_session(cwd: #{inspect(cwd)}, provider: {Elara.Provider.Scripted, agent})
        {:ok, child} = Threads.start_child(parent, "durable restart assignment", coding: true)
        Process.sleep(100)
        File.write!(Path.join(child["cwd"], "restart.txt"), "preserved on VM exit")
        File.write!(#{inspect(Path.join(root, "identity.json"))}, JSON.encode!(child))
        IO.puts("STARTED_BEFORE_VM_EXIT")
        System.halt(0)
        """

    assert {output, 0} =
             System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", start_code],
               stderr_to_stdout: true,
               env: [{"MIX_ENV", "test"}]
             )

    assert output =~ "STARTED_BEFORE_VM_EXIT"

    restart_code =
      common <>
        """
        child = JSON.decode!(File.read!(#{inspect(Path.join(root, "identity.json"))}))
        {:ok, agent} = Agent.start_link(fn -> [{:ok, reply}] end)
        {:ok, id} = Threads.resume(child["id"], provider: {Elara.Provider.Scripted, agent})
        true = id == child["id"]
        true = File.read!(Path.join(Elara.cwd(id), "restart.txt")) == "preserved on VM exit"
        [%Message.User{text: "durable restart assignment"}] = Elara.transcript(id)
        true = Elara.snapshot(id).snapshot["inbox"]["paused"]
        {:ok, "explicit restart answer"} = Elara.ask(id, "explicit follow-up after restart")
        IO.puts("FULL_RESTART_VERIFIED")
        """

    assert {output, 0} =
             System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", restart_code],
               stderr_to_stdout: true,
               env: [{"MIX_ENV", "test"}]
             )

    assert output =~ "FULL_RESTART_VERIFIED"
  end

  defmodule SettingsProvider do
    def chat(config, _request) do
      {:ok, message} = Elara.Message.assistant("model=#{config.model}", [])
      {:ok, message, config}
    end
  end

  test "effective model survives resume without persisting provider secrets", %{
    cwd: cwd,
    root: root
  } do
    provider = {SettingsProvider, %{model: "original-model", token: "private-test-sentinel"}}
    {:ok, parent} = Elara.start_session(cwd: cwd, provider: provider)
    {:ok, child} = Threads.start_child(parent, "retain model")
    finished(parent, child["id"])
    assert child["model"] == "original-model"

    for path <- Path.wildcard(Path.join(root, "sessions/_threads/*.json")) do
      refute File.read!(path) =~ "private-test-sentinel"
    end

    stop(child["id"])

    assert {:ok, id} =
             Threads.resume(child["id"],
               provider: {SettingsProvider, %{model: "changed-default", token: "fresh"}}
             )

    assert {:ok, "model=original-model"} = Elara.ask(id, "resume settings")
    finished(parent, id)
    assert Enum.find(Threads.list(parent).children, &(&1["id"] == id))["state"] == "completed"
  end

  test "real PTY starts two children, inspects and opens coding work, then resumes after server restart",
       %{cwd: cwd, root: root} do
    {parent, provider} =
      parent(
        cwd,
        [
          answer(nil, [
            %ToolCall{
              id: "pty-write",
              name: "write",
              args: {:ok, %{"path" => "pty.txt", "content" => "actual child mutation"}}
            },
            %ToolCall{
              id: "pty-uncertain",
              name: "bash",
              args: {:ok, %{"command" => "yes"}}
            }
          ]),
          answer("PTY coding answer"),
          {:error, %Elara.Provider.Error{kind: :bad_response, message: "PTY research failure"}},
          answer("PTY resumed answer")
        ],
        max_tool_output_bytes: 256
      )

    :ok = Elara.name_session(parent, "PTY parent")
    binary = Path.join(root, "elara-tui")
    File.cp!(Mix.Tasks.Elara.Tui.binary!(), binary)
    File.chmod!(binary, 0o700)

    for stage <- ["start", "resume"] do
      {:ok, server} = Elara.Server.start_link(port: 0, provider: provider, lifetime: :long_lived)

      {output, status} =
        System.cmd(
          "python3",
          [
            Path.expand("../support/threads_pty.py", __DIR__),
            binary,
            Integer.to_string(Elara.Server.port(server)),
            parent,
            stage
          ],
          cd: cwd,
          env: [
            {"ELARA_TUI_STATE_DIR", Path.join(root, "tui")},
            {"ELARA_TUI_APPEARANCE_FILE", Path.join(root, "appearance.json")}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "THREAD PTY #{stage} passed"
      children = Threads.list(parent).children
      coding = Enum.find(children, & &1["coding"])
      assert File.read!(Path.join(coding["cwd"], "pty.txt")) == "actual child mutation"
      refute File.exists?(Path.join(cwd, "pty.txt"))

      if stage == "resume" do
        assert List.last(Elara.transcript(coding["id"])).text == "PTY resumed answer"

        assert Enum.count(
                 Elara.transcript(coding["id"]),
                 &match?(%Message.User{text: "PTY coding λ"}, &1)
               ) == 1
      end

      Enum.each(children, &stop(&1["id"]))
      stop(parent)
      GenServer.stop(server)
    end
  end
end
