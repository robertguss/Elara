defmodule Elara.FnoxTest do
  use ExUnit.Case, async: false

  alias Elara.{Fnox, Output, Tool}
  alias Elara.Message.{Assistant, ToolCall, ToolResult}

  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    File.cp!("test/support/fixtures/fnox.py", Path.join(bin, "fnox"))
    File.chmod!(Path.join(bin, "fnox"), 0o755)
    old = Map.new(["PATH", "FNOX_PROFILE", "ELARA_API_KEY"], &{&1, System.get_env(&1)})
    System.put_env("PATH", bin <> ":" <> old["PATH"])
    System.put_env("FNOX_PROFILE", "production")
    System.put_env("ELARA_API_KEY", "fixture-elara-never-forward")
    files = Enum.map(~w(fnox.toml imported.toml global.toml), &Path.join(root, &1))
    Enum.each(files, &File.write!(&1, "# approved fixture\n"))
    File.write!(Path.join(root, ".fnox-inventory"), Enum.join(files, "\n") <> "\n")

    plan = %{
      "schema" => 1,
      "scope" => "exec",
      "profile" => ["default"],
      "set" => %{"DATABASE_URL" => "fixture-database-secret"},
      "files" => %{},
      "remove" => ["FNOX_AGE_KEY"],
      "missing" => [],
      "leases" => []
    }

    write_plan(root, plan)

    on_exit(fn ->
      for {name, value} <- old do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    {:ok, root: root, files: files, plan: plan}
  end

  test "fnox approval rechecks byte changes and cannot bypass exact command approval", %{
    root: root,
    files: files
  } do
    command = "printf '%s' \"$DATABASE_URL\"; touch executed"
    File.mkdir_p!(Path.join(root, ".elara"))

    File.write!(
      Path.join(root, ".elara/command-rules.json"),
      JSON.encode!(%{"ask" => ["touch executed"]})
    )

    {:ok, script} =
      Agent.start_link(fn ->
        [
          {:ok,
           %Assistant{
             tool_calls: [
               %ToolCall{id: "secrets", name: "bash", args: {:ok, %{"command" => command}}}
             ]
           }},
          {:ok, %Assistant{text: "done"}}
        ]
      end)

    {:ok, session} =
      Elara.start_session(cwd: root, plugins: [], provider: {Elara.Provider.Scripted, script})

    on_exit(fn ->
      case Elara.session_pid(session) do
        {:ok, pid} -> GenServer.stop(pid)
        _ -> :ok
      end
    end)

    :ok = Elara.subscribe(session)
    {:ok, _} = Elara.attach(session, :control)
    assert :ok = Elara.ask_async(session, "run the command")
    assert_receive {:elara, ^session, {:approval_required, pending}}, 3_000
    assert pending["kind"] == "fnox"
    assert Enum.map(pending["fnox_config"]["files"], & &1["path"]) == Enum.sort(files)
    refute JSON.encode!(pending) =~ "fixture-database-secret"
    File.write!(Enum.at(files, 1), "# changed import\n")

    assert {:error, :approval_changed} =
             Elara.attached_command(session, {:approve, pending["id"]})

    assert_receive {:elara, ^session, {:approval_required, changed}}, 3_000
    refute changed["id"] == pending["id"]
    assert :ok = Elara.attached_command(session, {:approve, changed["id"]})
    assert_receive {:elara, ^session, {:approval_required, call}}, 3_000
    assert call["kind"] == "call"
    refute File.exists?(Path.join(root, "executed"))
    assert :ok = Elara.attached_command(session, {:approve, call["id"]})
    assert_receive {:elara, ^session, {:turn_ended, {:completed, "done"}}}, 3_000
    assert File.exists?(Path.join(root, "executed"))

    [%ToolResult{outcome: {:ok, text}}] =
      Enum.filter(Elara.transcript(session), &is_struct(&1, ToolResult))

    assert text =~ "[fnox:DATABASE_URL]"
    refute text =~ "fixture-database-secret"
    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(session))
  end

  test "redaction precedes retained bytes, including file secrets and output_read", %{
    root: root,
    plan: plan
  } do
    plan = %{plan | "files" => %{"CERTIFICATE" => "fixture-cert\nsecond-line"}}
    write_plan(root, plan)
    {:ok, config} = Fnox.review(root)

    ctx = %Tool.Ctx{
      session_id: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      cwd: root,
      fnox_config: config
    }

    command =
      "python3 -c 'import os,sys; v=os.environ[\"DATABASE_URL\"]; " <>
        "[sys.stdout.write(str(i)+\":\"+v+\"\\n\") for i in range(1500)]; " <>
        "sys.stderr.write(open(os.environ[\"CERTIFICATE\"]).read())'"

    assert {:ok, preview} = Elara.Tools.bash(%{"command" => command}, ctx)
    assert preview =~ "[fnox:DATABASE_URL]"
    [_, handle] = Regex.run(~r/\A\[output (out_[A-Za-z0-9_-]+);/, preview)
    assert {:ok, middle} = Output.read(ctx, handle, {:literal, "731:", 1, 1})
    assert middle =~ "731:[fnox:DATABASE_URL]"
    assert {:ok, cert} = Output.read(ctx, handle, {:literal, "[fnox:CERTIFICATE]", 1, 1})
    assert cert =~ "[fnox:CERTIFICATE]"
    {:ok, state_root} = Elara.Session.Store.root()

    for path <- Path.wildcard(Path.join(state_root, "**/*.bytes")) do
      refute File.read!(path) =~ "fixture-database-secret"
      refute File.read!(path) =~ "fixture-cert"
    end

    assert File.ls!(Path.join(state_root, "_fnox")) == []
  end

  test "plugin-style execution removes private file secrets when its caller dies", %{
    root: root,
    plan: plan
  } do
    write_plan(root, %{plan | "files" => %{"CERTIFICATE" => "fixture-cert"}})
    {:ok, config} = Fnox.review(root)
    ctx = %Tool.Ctx{cwd: root, fnox_config: config}
    marker = Path.join(root, "secret-path")

    task =
      Task.Supervisor.async_nolink(Elara.TaskSup, fn ->
        Fnox.exec(ctx, ["bash", "-c", "printf '%s' \"$CERTIFICATE\" > secret-path; sleep 30"],
          cwd: root,
          timeout_ms: 30_000,
          max_bytes: 1000
        )
      end)

    assert eventually(fn -> File.exists?(marker) and File.read!(marker) != "" end)
    path = File.read!(marker)
    assert File.read!(path) == "fixture-cert"
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    Process.exit(task.pid, :kill)
    assert_receive {:DOWN, ref, :process, _, :killed} when ref == task.ref
    assert eventually(fn -> not File.exists?(path) end)
  end

  test "a post-resolution change discards the entire plan and never starts the command", %{
    root: root,
    plan: plan,
    files: files
  } do
    {:ok, config} = Fnox.review(root)
    write_plan(root, Map.put(plan, "test_change", hd(files)))
    ctx = %Tool.Ctx{session_id: Path.basename(root), cwd: root, fnox_config: config}

    assert {:error, "fnox config changed; /approve again"} =
             Elara.Tools.bash(%{"command" => "touch should-not-run"}, ctx)

    refute File.exists?(Path.join(root, "should-not-run"))
  end

  test "noninteractive resolution is bounded and forbidden credential names refuse the plan", %{
    root: root,
    plan: plan
  } do
    {:ok, config} = Fnox.review(root)

    ctx = %Tool.Ctx{
      session_id: Path.basename(root),
      cwd: root,
      fnox_config: config,
      timeout_ms: 80
    }

    write_plan(root, Map.put(plan, "test_delay", 10))
    assert {:error, reason} = Elara.Tools.bash(%{"command" => "touch forbidden"}, ctx)
    assert reason =~ "unlock/authenticate"
    write_plan(root, put_in(plan["set"]["ELARA_API_KEY"], "fixture-forbidden"))

    assert {:error, _} =
             Elara.Tools.bash(%{"command" => "touch forbidden"}, %{ctx | timeout_ms: 3000})

    refute File.exists?(Path.join(root, "forbidden"))
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end

  defp write_plan(root, plan), do: File.write!(Path.join(root, ".fnox-plan"), JSON.encode!(plan))
end
