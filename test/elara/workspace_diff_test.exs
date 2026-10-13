defmodule Elara.WorkspaceDiffTest do
  use ExUnit.Case, async: false
  alias Elara.Message.{Assistant, ToolCall}

  setup do
    root = Path.join(System.tmp_dir!(), "elara-diff-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{cwd: root}
  end

  defp git(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end

  defp call(name, args), do: %ToolCall{id: name, name: name, args: {:ok, args}}

  defp start(cwd, replies, options \\ []) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    {:ok, id} =
      Elara.start_session(
        [
          cwd: cwd,
          home: cwd,
          skill_paths: [],
          plugins: [],
          provider: {Elara.Provider.Scripted, agent}
        ] ++ options
      )

    on_exit(fn -> stop(id) end)
    id
  end

  defp stop(id) do
    case Elara.session_pid(id) do
      {:ok, pid} -> if Process.alive?(pid), do: GenServer.stop(pid)
      _ -> :ok
    end
  end

  test "turn and session diffs cover edits and bash, separate outside edits, retain snapshots on reopen",
       %{cwd: cwd} do
    git(cwd, ["init", "--quiet"])
    File.write!(Path.join(cwd, "tracked.ex"), "committed\n")
    File.write!(Path.join(cwd, ".gitignore"), "deps/\n")
    git(cwd, ["add", "."])

    git(cwd, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@localhost",
      "commit",
      "--quiet",
      "-m",
      "fixture"
    ])

    File.write!(Path.join(cwd, "tracked.ex"), "staged\n")
    git(cwd, ["add", "tracked.ex"])
    File.write!(Path.join(cwd, "tracked.ex"), "before\n")
    File.mkdir_p!(Path.join(cwd, "deps"))
    File.write!(Path.join(cwd, "deps/secret.txt"), "ignored-canary")
    index = File.read!(Path.join(cwd, ".git/index"))
    head = File.read!(Path.join(cwd, ".git/HEAD"))

    session =
      start(cwd, [
        {:ok,
         %Assistant{
           tool_calls: [
             call("edit", %{"path" => "tracked.ex", "old_text" => "before", "new_text" => "first"}),
             call("bash", %{
               "command" =>
                 "printf 'created by bash\\n' > created.txt; printf '\\000binary-canary' > binary.bin; head -c 140000 /dev/zero | tr '\\000' x > large.txt"
             })
           ]
         }},
        {:ok, %Assistant{text: "first done"}},
        {:ok,
         %Assistant{
           tool_calls: [
             call("edit", %{"path" => "tracked.ex", "old_text" => "first", "new_text" => "second"})
           ]
         }},
        {:ok, %Assistant{text: "second done"}}
      ])

    assert {:ok, "first done"} = Elara.ask(session, "edit and create with bash")
    assert {:ok, turn} = Elara.workspace_diff(session)
    assert turn =~ "git-visible files; ignored files not shown"
    assert turn =~ "closed endpoint"
    assert turn =~ "-before"
    assert turn =~ "+first"
    assert turn =~ "+created by bash"
    assert turn =~ "binary file"
    assert turn =~ "large file"
    refute turn =~ "binary-canary"
    refute turn =~ "ignored-canary"
    assert File.read!(Path.join(cwd, ".git/index")) == index
    assert File.read!(Path.join(cwd, ".git/HEAD")) == head

    File.write!(Path.join(cwd, "outside.txt"), "outside-one\n")
    assert {:ok, outside} = Elara.workspace_diff(session)
    [attributed, outside] = String.split(outside, "Changed outside Elara")
    refute attributed =~ "outside-one"
    assert outside =~ "+outside-one"

    assert {:ok, "second done"} = Elara.ask(session, "second edit")
    assert {:ok, latest} = Elara.workspace_diff(session)
    assert latest =~ "-first"
    assert latest =~ "+second"
    refute String.split(latest, "Changed outside Elara") |> hd() =~ "created by bash"
    assert latest =~ "+outside-one"
    assert {:ok, net} = Elara.workspace_diff(session, :session)
    assert net =~ "-before"
    assert net =~ "+second"
    assert net =~ "+created by bash"

    {:ok, info} = Elara.Session.Store.newest(cwd)
    stop(session)
    reopened = start(cwd, [], resume: info.path)
    assert {:ok, ^latest} = Elara.workspace_diff(reopened)
    assert {:ok, ^net} = Elara.workspace_diff(reopened, :session)
    assert File.read!(Path.join(cwd, ".git/index")) == index
    assert File.read!(Path.join(cwd, ".git/HEAD")) == head
  end

  test "unborn Git captures staged files; non-Git reports unavailable", %{cwd: cwd} do
    plain = start(cwd, [{:ok, %Assistant{text: "plain"}}])
    assert {:ok, "plain"} = Elara.ask(plain, "hello")
    assert {:error, message} = Elara.workspace_diff(plain)
    assert message =~ "not a Git repository"
    stop(plain)

    git(cwd, ["init", "--quiet"])
    File.write!(Path.join(cwd, "staged.txt"), "before\n")
    git(cwd, ["add", "staged.txt"])
    index = File.read!(Path.join(cwd, ".git/index"))

    session =
      start(cwd, [
        {:ok,
         %Assistant{
           tool_calls: [
             call("edit", %{"path" => "staged.txt", "old_text" => "before", "new_text" => "after"})
           ]
         }},
        {:ok, %Assistant{text: "done"}}
      ])

    assert {:ok, "done"} = Elara.ask(session, "change staged unborn file")
    assert {:ok, report} = Elara.workspace_diff(session)
    assert report =~ "-before"
    assert report =~ "+after"
    assert File.read!(Path.join(cwd, ".git/index")) == index
    assert {_, 128} = System.cmd("git", ["rev-parse", "HEAD"], cd: cwd, stderr_to_stdout: true)
  end

  test "fork and clone start at copy time, not inherited turns, and separate pre-turn outside edits",
       %{cwd: cwd} do
    git(cwd, ["init", "--quiet"])

    for mode <- [:fork, :clone] do
      File.write!(Path.join(cwd, "file.txt"), "pre-source\n")
      File.rm(Path.join(cwd, "outside.txt"))

      source =
        start(cwd, [
          {:ok,
           %Assistant{
             tool_calls: [
               call("edit", %{
                 "path" => "file.txt",
                 "old_text" => "pre-source",
                 "new_text" => "source"
               })
             ]
           }},
          {:ok, %Assistant{text: "source done"}},
          {:ok,
           %Assistant{
             tool_calls: [
               call("edit", %{
                 "path" => "file.txt",
                 "old_text" => "source",
                 "new_text" => "copied"
               })
             ]
           }},
          {:ok, %Assistant{text: "copy done"}}
        ])

      assert {:ok, "source done"} = Elara.ask(source, "source turn")

      result =
        if mode == :clone,
          do: Elara.clone_session(source),
          else: Elara.fork(source, hd(Elara.user_entries(source)).id)

      copy =
        case result do
          {:ok, id, _, _} -> id
          {:ok, _, _} -> source
        end

      on_exit(fn -> stop(copy) end)
      assert {:ok, fresh} = Elara.workspace_diff(copy, :session)
      assert fresh =~ "Fresh baseline at fork/clone copy time"
      assert fresh =~ "No changes."
      refute fresh =~ "pre-source"
      File.write!(Path.join(cwd, "outside.txt"), "outside-before-copy-turn\n")
      assert {:ok, "copy done"} = Elara.ask(copy, "copy turn")
      assert {:ok, report} = Elara.workspace_diff(copy, :session)
      assert report =~ "-source"
      assert report =~ "+copied"
      refute report =~ "pre-source"
      assert report =~ "Changed outside Elara"
      assert report =~ "+outside-before-copy-turn"
      stop(copy)
      stop(source)
    end
  end

  test "diff follows the handoff owner and labels the successor-only session view", %{cwd: cwd} do
    git(cwd, ["init", "--quiet"])
    File.write!(Path.join(cwd, "file.txt"), "before\n")

    source =
      start(
        cwd,
        [
          {:ok,
           %Assistant{
             tool_calls: [
               call("edit", %{
                 "path" => "file.txt",
                 "old_text" => "before",
                 "new_text" => "successor"
               })
             ]
           }},
          {:ok, %Assistant{text: "successor done"}}
        ],
        context_limit: 100_000,
        seed_history: [
          Elara.Message.user("goal"),
          %Assistant{text: String.duplicate("x", 60_000), usage: %{"input_tokens" => 90_000}}
        ]
      )

    assert {:error, :interrupted} = Elara.ask(source, "continue the goal")
    deadline = System.monotonic_time(:millisecond) + 5000

    owner =
      Stream.repeatedly(fn ->
        if System.monotonic_time(:millisecond) > deadline,
          do:
            flunk(
              "handoff did not transfer ownership: #{inspect(Elara.snapshot(source).snapshot["inbox"]["handoff"])}"
            )

        Process.sleep(10)
        Elara.snapshot(source).snapshot["inbox"]["handoff"]["delivery_owner"]
      end)
      |> Enum.find(&is_binary/1)

    assert is_binary(owner) and owner != source
    on_exit(fn -> stop(owner) end)

    report =
      Stream.repeatedly(fn -> Elara.workspace_diff(source) end)
      |> Enum.find(fn result ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("successor did not close its turn")

        Process.sleep(10)

        match?({:ok, _}, result) and elem(result, 1) =~ "closed endpoint" and
          elem(result, 1) =~ "+successor"
      end)

    assert {:ok, latest} = report
    assert {:ok, ^latest} = Elara.workspace_diff(owner)
    assert {:ok, session} = Elara.workspace_diff(source, :session)
    assert session =~ "Unavailable before successor start; showing from there"
    assert session =~ "+successor"
  end
end
