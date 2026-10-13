defmodule Elara.WorkspaceSearchProductTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Elara.Message
  alias Elara.Message.{ToolCall, ToolResult}
  alias Elara.Session.Store
  alias Elara.Tool
  alias Elara.Tool.Ctx
  alias Elara.Tools.Search

  @moduletag :requires_app
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    target = Path.join(root, "selected workspace")
    File.mkdir_p!(Path.join(target, "lib"))
    File.write!(Path.join(target, "lib/only.ex"), "defmodule Only do\n  @marker :selected\nend\n")

    previous_sessions = Application.get_env(:elara, :sessions_root)
    previous_trust = Application.get_env(:elara, :plugin_trust_root)
    Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))
    Application.put_env(:elara, :plugin_trust_root, Path.join(root, "trust"))
    existing = MapSet.new(Elara.live_sessions(), & &1.id)

    on_exit(fn ->
      for session <- Elara.live_sessions(), not MapSet.member?(existing, session.id) do
        {:ok, pid} = Elara.session_pid(session.id)
        DynamicSupervisor.terminate_child(Elara.SessionSup, pid)
      end

      restore(:sessions_root, previous_sessions)
      restore(:plugin_trust_root, previous_trust)
    end)

    %{target: target, invoking: File.cwd!()}
  end

  defp restore(key, nil), do: Application.delete_env(:elara, key)
  defp restore(key, value), do: Application.put_env(:elara, key, value)

  test "a missing ripgrep is one actionable error, not a silent fallback", %{target: target} do
    previous = Application.get_env(:elara, :ripgrep_path)
    Application.put_env(:elara, :ripgrep_path, Path.join(target, "absent-rg"))
    on_exit(fn -> restore(:ripgrep_path, previous) end)

    ctx = %Ctx{cwd: target}

    for result <- [
          Search.grep(%{"pattern" => "marker"}, ctx),
          Search.glob(%{"pattern" => "**/*.ex"}, ctx)
        ] do
      assert {:error, message} = result
      assert message =~ "requires the ripgrep executable (rg) on PATH"
      assert message =~ "no fallback matcher"
    end

    # The roster stays host-independent so prompts and recordings do not vary.
    names = Enum.map(Tool.builtins(), & &1.name)
    assert "grep" in names
    assert "glob" in names
  end

  test "recursive search skips protected files and aliases before reading contents", %{
    target: target
  } do
    private = Path.join(target, "private[state]")
    Application.put_env(:elara, :sessions_root, private)

    for path <- [".envrc", ".profile", "fish/config.fish", "private[state]/auth.json"] do
      full = Path.join(target, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "marker PRIVATE_FIXTURE_ONLY\n")
    end

    File.ln_s!(Path.join(private, "auth.json"), Path.join(target, "alias.json"))
    File.ln_s!(private, Path.join(target, "alias-dir"))
    ctx = %Ctx{cwd: target}

    for args <- [%{"pattern" => "marker"}, %{"pattern" => "marker", "glob" => "**/*"}] do
      assert Search.grep(args, ctx) == {:ok, "lib/only.ex:2:  @marker :selected"}
    end

    assert Search.glob(%{"pattern" => "**/*"}, ctx) == {:ok, "lib/only.ex"}

    for path <- [
          ".envrc",
          ".profile",
          "fish/config.fish",
          "private[state]",
          "alias.json",
          "alias-dir"
        ] do
      assert {:error, "file access refused: protected_path"} =
               Search.grep(%{"pattern" => "marker", "path" => path}, ctx)

      assert {:error, "file access refused: protected_path"} =
               Search.glob(%{"pattern" => "**/*", "path" => path}, ctx)
    end
  end

  test "search resolves scopes and permits only operator-approved extra roots", %{target: target} do
    outside = Path.join(Path.dirname(target), "other source")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "other.ex"), "marker outside\n")
    File.ln_s!(outside, Path.join(target, "outside-link"))
    ctx = %Ctx{cwd: target}

    for path <- [outside, "outside-link", Path.join(outside, "other.ex")] do
      assert {:error, "file access refused: path_outside_workspace"} =
               Search.grep(%{"pattern" => "marker", "path" => path}, ctx)

      assert {:error, "file access refused: path_outside_workspace"} =
               Search.glob(%{"pattern" => "**/*", "path" => path}, ctx)
    end

    previous = System.get_env("ELARA_FILE_ROOTS")
    System.put_env("ELARA_FILE_ROOTS", outside)

    on_exit(fn ->
      if previous,
        do: System.put_env("ELARA_FILE_ROOTS", previous),
        else: System.delete_env("ELARA_FILE_ROOTS")
    end)

    for path <- [outside, "outside-link"] do
      assert Search.grep(%{"pattern" => "marker", "path" => path}, ctx) ==
               {:ok, "#{outside}/other.ex:1:marker outside"}

      assert Search.glob(%{"pattern" => "**/*.ex", "path" => path}, ctx) ==
               {:ok, "#{outside}/other.ex"}
    end
  end

  test "a workspace selected with --cwd is the search root, not the launch directory", context do
    %{target: target, invoking: invoking} = context

    calls = [
      %ToolCall{id: "glob", name: "glob", args: {:ok, %{"pattern" => "**/*.ex"}}},
      %ToolCall{id: "grep", name: "grep", args: {:ok, %{"pattern" => "@marker"}}},
      %ToolCall{
        id: "escape",
        name: "grep",
        args: {:ok, %{"pattern" => "@marker", "path" => "../"}}
      }
    ]

    {:ok, script} =
      Agent.start_link(fn ->
        [{:ok, assistant(nil, calls)}, {:ok, assistant("searched the selected workspace")}]
      end)

    provider = {Elara.Provider.Scripted, script}
    relative = Path.relative_to(target, invoking, force: true)

    output =
      capture_io(fn ->
        assert :ok = Elara.CLI.main(["--cwd", relative, "find the marker"], provider: provider)
      end)

    assert output =~ "searched the selected workspace"
    assert [session] = Enum.filter(Elara.live_sessions(), &(&1.cwd == target))

    results =
      for %ToolResult{call_id: id, outcome: outcome} <- Elara.transcript(session.id),
          into: %{},
          do: {id, outcome}

    # The launch checkout holds hundreds of .ex files; one proves the root moved.
    assert results["glob"] == {:ok, "lib/only.ex"}
    assert results["grep"] == {:ok, "lib/only.ex:2:  @marker :selected"}
    assert {:error, escape} = results["escape"]
    assert escape == "file access refused: path_outside_workspace"

    assert File.cwd!() == invoking
    assert Store.list(target, include_empty: true) == []
  end

  defp assistant(text, calls \\ []) do
    {:ok, message} = Message.assistant(text, calls)
    message
  end
end
