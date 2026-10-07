defmodule Elara.CLIWorkspaceTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Elara.Message
  alias Elara.Message.{ToolCall, ToolResult}
  alias Elara.Session.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    target = Path.join(root, "target workspace")
    other = Path.join(root, "other workspace")
    for path <- [target, other], do: File.mkdir_p!(path)
    previous = Application.get_env(:elara, :sessions_root)
    previous_trust = Application.get_env(:elara, :plugin_trust_root)
    Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))
    Application.put_env(:elara, :plugin_trust_root, Path.join(root, "trust"))
    existing = MapSet.new(Elara.live_sessions(), & &1.id)

    on_exit(fn ->
      for session <- Elara.live_sessions(), not MapSet.member?(existing, session.id) do
        {:ok, pid} = Elara.session_pid(session.id)
        DynamicSupervisor.terminate_child(Elara.SessionSup, pid)
      end

      Application.put_env(:elara, :sessions_root, previous)

      if previous_trust,
        do: Application.put_env(:elara, :plugin_trust_root, previous_trust),
        else: Application.delete_env(:elara, :plugin_trust_root)
    end)

    %{target: target, other: other, root: root, invoking: File.cwd!()}
  end

  defp assistant(text, calls \\ []) do
    {:ok, message} = Message.assistant(text, calls)
    message
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp chat(argv, provider) do
    {:ok, remaining, opts} = Mix.Tasks.Elara.Chat.parse_args(argv)

    capture_io([input: "/quit\n"], fn ->
      assert catch_exit(Elara.Chat.main(remaining, opts ++ [provider: provider])) ==
               {:shutdown, 0}
    end)
  end

  defp stop(id) do
    {:ok, pid} = Elara.session_pid(id)
    :ok = DynamicSupervisor.terminate_child(Elara.SessionSup, pid)
  end

  defp waiting_stdio(out, pending \\ nil) do
    receive do
      {:io_request, from, ref, {:get_line, _encoding, _prompt}} ->
        waiting_stdio(out, {from, ref})

      {:io_request, _from, _ref, _request} = request ->
        send(out, request)
        waiting_stdio(out, pending)

      :close ->
        if pending do
          {from, ref} = pending
          send(from, {:io_reply, ref, :eof})
        end
    end
  end

  defp await_output(out, text, attempts \\ 100) do
    {_input, output} = StringIO.contents(out)

    cond do
      String.contains?(output, text) ->
        output

      attempts == 0 ->
        flunk("missing #{inspect(text)} in #{inspect(output)}")

      true ->
        Process.sleep(10)
        await_output(out, text, attempts - 1)
    end
  end

  test "real ask startup uses target tools, instructions and skills, without persistence", ctx do
    File.write!(Path.join(ctx.target, "AGENTS.md"), "TARGET_WORKSPACE_GUIDANCE")
    File.write!(Path.join(ctx.other, "AGENTS.md"), "OTHER_WORKSPACE_GUIDANCE")
    File.write!(Path.join(ctx.target, "input.txt"), "target input")
    skill = Path.join(ctx.target, ".agents/skills/testing-workspaces")
    File.mkdir_p!(skill)

    File.write!(
      Path.join(skill, "SKILL.md"),
      "---\nname: testing-workspaces\ndescription: Tests target workspace discovery. Use for workspace tests.\n---\nTARGET_SKILL_BODY\n"
    )

    output_name = "cwd-proof-#{System.unique_integer([:positive])}.txt"

    calls = [
      %ToolCall{id: "read", name: "read", args: {:ok, %{"path" => "input.txt"}}},
      %ToolCall{
        id: "write",
        name: "write",
        args: {:ok, %{"path" => output_name, "content" => "target write"}}
      },
      %ToolCall{id: "pwd", name: "bash", args: {:ok, %{"command" => "pwd"}}},
      %ToolCall{id: "skill", name: "skill", args: {:ok, %{"name" => "testing-workspaces"}}}
    ]

    provider = script([{:ok, assistant(nil, calls)}, {:ok, assistant("workspace done")}])
    relative = Path.relative_to(ctx.target, ctx.invoking, force: true)

    output =
      capture_io(fn ->
        assert :ok = Elara.CLI.main(["--cwd", relative, "inspect workspace"], provider: provider)
      end)

    assert output =~ "workspace done"
    assert [session] = Elara.live_sessions() |> Enum.filter(&(&1.cwd == ctx.target))
    assert File.read!(Path.join(ctx.target, output_name)) == "target write"
    refute File.exists?(Path.join(ctx.invoking, output_name))
    refute File.exists?(Path.join(ctx.other, output_name))

    results =
      for %ToolResult{call_id: id, outcome: result} <- Elara.transcript(session.id),
          into: %{},
          do: {id, result}

    assert results["read"] == {:ok, "target input"}
    assert {:ok, pwd} = results["pwd"]
    assert String.trim(pwd) == ctx.target
    assert {:ok, skill_body} = results["skill"]
    assert skill_body =~ "TARGET_SKILL_BODY"
    system = hd(Elara.recording(session.id).segments).seed.config.system
    assert system =~ "TARGET_WORKSPACE_GUIDANCE"
    refute system =~ "OTHER_WORKSPACE_GUIDANCE"
    assert Store.list(ctx.target, include_empty: true) == []
    assert File.cwd!() == ctx.invoking
  end

  test "chat startup naming, continue and resume stay in the selected workspace", ctx do
    assert chat(["--cwd", ctx.target, "--name", "selected chat"], script([])) =~ "elara"
    assert [named] = Store.list(ctx.target, include_empty: true)
    assert named.name == "selected chat"
    stop(named.id)

    for {cwd, prompt, answer} <- [
          {ctx.target, "target question", "target answer"},
          {ctx.other, "other question", "other answer"}
        ] do
      store =
        if cwd == ctx.target do
          {:ok, store} = Store.open(named.path)
          store
        else
          Store.new(cwd)
        end

      {:ok, store} = Store.append(store, Message.user(prompt))
      {:ok, _store} = Store.append(store, assistant(answer))
    end

    continued = chat(["--cwd", ctx.target, "--continue"], script([]))
    assert continued =~ "target question"
    assert continued =~ "target answer"
    refute continued =~ "other answer"
    [active] = Enum.filter(Elara.live_sessions(), &(&1.cwd == ctx.target))
    stop(active.id)

    {:ok, remaining, opts} = Mix.Tasks.Elara.Chat.parse_args(["--cwd", ctx.target])
    {:ok, out} = StringIO.open("")
    stdio = spawn(fn -> waiting_stdio(out) end)

    on_exit(fn ->
      send(stdio, :close)
      if Process.alive?(out), do: StringIO.close(out)
    end)

    provider = script([])

    task =
      Task.async(fn ->
        Process.group_leader(self(), stdio)
        catch_exit(Elara.Chat.main(remaining, opts ++ [provider: provider]))
      end)

    await_output(out, "> ")
    send(task.pid, {:stdin, "/resume\n"})
    resumed = await_output(out, "selected chat")
    assert resumed =~ named.id
    refute resumed =~ "other question"
    send(task.pid, {:stdin, "/resume 1\n"})
    assert await_output(out, "target answer") =~ "target answer"
    send(task.pid, {:stdin, "/quit\n"})
    assert Task.await(task) == {:shutdown, 0}
    assert File.cwd!() == ctx.invoking
  end

  test "selecting a repository never grants plugin approval", ctx do
    marker = Path.join(ctx.target, "plugin-compiled")
    path = Path.join(ctx.target, ".elara/plugins/unapproved.exs")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "File.write!(#{inspect(marker)}, \"compiled\")")
    {:ok, remaining, opts} = Mix.Tasks.Elara.Chat.parse_args(["--cwd", ctx.target])

    output =
      capture_io(:stderr, fn ->
        assert catch_exit(Elara.Chat.main(remaining, opts ++ [provider: script([])])) ==
                 {:shutdown, 1}
      end)

    assert output =~ "plugin_trust_required"
    refute File.exists?(marker)
    assert Enum.filter(Elara.live_sessions(), &(&1.cwd == ctx.target)) == []
  end
end
