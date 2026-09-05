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

    assert {:error, {:provider_error, %Elara.Provider.Error{kind: :resource_limit}}} =
             Elara.ask(idle_child["id"], "resumed turn also needs a slot")

    Elara.interrupt(parent)
    assert Enum.all?(children, &(Elara.status(&1["id"]).phase != :idle))
    assert {:ok, %{requested: ids}} = Threads.stop_subtree(parent)
    assert length(ids) == 6
    Enum.each(children, &finished(parent, &1["id"]))
    assert Enum.all?(children, &File.exists?(&1["session_path"]))
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

    for command <- ["child_start", "child_integrate", "child_cleanup", "child_stop_subtree"] do
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
    assert child["parent_cwd"] == cwd
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
      parent(cwd, [
        answer(nil, [
          %ToolCall{
            id: "pty-write",
            name: "write",
            args: {:ok, %{"path" => "pty.txt", "content" => "actual child mutation"}}
          }
        ]),
        answer("PTY coding answer"),
        {:error, %Elara.Provider.Error{kind: :bad_response, message: "PTY research failure"}},
        answer("PTY resumed answer")
      ])

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
