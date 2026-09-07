defmodule Elara.EditReplaceAllTest do
  use ExUnit.Case, async: true

  alias Elara.Tool
  alias Elara.Tool.Ctx
  alias Elara.Tools

  setup do
    dir = Path.join(System.tmp_dir!(), "elara-edit-all-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{ctx: %Ctx{cwd: dir}, dir: dir}
  end

  test "omitted or false replace_all rejects multiple matches without mutation", %{
    ctx: ctx,
    dir: dir
  } do
    path = Path.join(dir, "many.txt")
    File.write!(path, "one one one")

    assert {:error, msg} =
             Tools.edit(%{"path" => "many.txt", "old_text" => "one", "new_text" => "two"}, ctx)

    assert msg =~ "3 times"
    assert File.read!(path) == "one one one"

    assert {:error, msg} =
             Tools.edit(
               %{
                 "path" => "many.txt",
                 "old_text" => "one",
                 "new_text" => "two",
                 "replace_all" => false
               },
               ctx
             )

    assert msg =~ "3 times"
    assert File.read!(path) == "one one one"
  end

  test "true replace_all replaces non-overlapping literal occurrences in one pass", %{
    ctx: ctx,
    dir: dir
  } do
    path = Path.join(dir, "all.txt")
    File.write!(path, "aaaa")

    assert {:ok, "edited all.txt"} =
             Tools.edit(
               %{
                 "path" => "all.txt",
                 "old_text" => "aa",
                 "new_text" => "aaa",
                 "replace_all" => true
               },
               ctx
             )

    assert File.read!(path) == "aaaaaa"
  end

  test "replace_all preserves bytes and permits deletion", %{ctx: ctx, dir: dir} do
    path = Path.join(dir, "bytes.txt")
    original = "α\r\nneedle\r\nβneedle"
    File.write!(path, original)

    assert {:ok, _} =
             Tools.edit(
               %{
                 "path" => "bytes.txt",
                 "old_text" => "needle",
                 "new_text" => "",
                 "replace_all" => true
               },
               ctx
             )

    assert File.read!(path) == "α\r\n\r\nβ"
  end

  test "replace_all errors do not mutate", %{ctx: ctx, dir: dir} do
    path = Path.join(dir, "errors.txt")
    File.write!(path, "abc abc")

    for args <- [
          %{"path" => "errors.txt", "old_text" => "", "new_text" => "x", "replace_all" => true},
          %{
            "path" => "errors.txt",
            "old_text" => "abc",
            "new_text" => "x",
            "replace_all" => "true"
          },
          %{
            "path" => "errors.txt",
            "old_text" => "missing",
            "new_text" => "x",
            "replace_all" => true
          }
        ] do
      assert {:error, _} = Tools.edit(args, ctx)
      assert File.read!(path) == "abc abc"
    end
  end

  test "edit tool schema exposes replace_all and version 2" do
    edit_tool = Enum.find(Tool.builtins(), &(&1.name == "edit"))

    assert edit_tool.version == "2"
    assert edit_tool.parameters["properties"]["replace_all"]["type"] == "boolean"
  end

  test "all modes preserve single-match behavior and uninterpreted surrounding bytes", %{
    ctx: ctx,
    dir: dir
  } do
    path = Path.join(dir, "single.bin")

    for option <- [%{}, %{"replace_all" => false}, %{"replace_all" => true}] do
      File.write!(path, <<255>> <> "a.b\r\nlast")

      args =
        Map.merge(%{"path" => "single.bin", "old_text" => "a.b", "new_text" => "$1\\α"}, option)

      assert {:ok, "edited single.bin"} = Tools.edit(args, ctx)
      assert File.read!(path) == <<255>> <> "$1\\α\r\nlast"
    end
  end

  test "invalid flags and empty patterns cannot mutate even a unique match", %{ctx: ctx, dir: dir} do
    path = Path.join(dir, "invalid.txt")
    File.write!(path, "needle")
    args = %{"path" => "invalid.txt", "old_text" => "needle", "new_text" => "changed"}

    for invalid <- [nil, "true", "false", 0, 1, [], %{}] do
      assert {:error, message} = Tools.edit(Map.put(args, "replace_all", invalid), ctx)
      assert message =~ "boolean"
      assert File.read!(path) == "needle"
    end

    for option <- [%{}, %{"replace_all" => false}, %{"replace_all" => true}] do
      assert {:error, message} = Tools.edit(Map.merge(%{args | "old_text" => ""}, option), ctx)
      assert message =~ "empty"
      assert File.read!(path) == "needle"
    end
  end

  test "missing matches, missing files and directories remain ordinary errors", %{
    ctx: ctx,
    dir: dir
  } do
    args = %{
      "path" => "empty.txt",
      "old_text" => "missing",
      "new_text" => "x",
      "replace_all" => true
    }

    File.write!(Path.join(dir, "empty.txt"), "")
    assert {:error, message} = Tools.edit(args, ctx)
    assert message =~ "not found"
    assert File.read!(Path.join(dir, "empty.txt")) == ""
    assert {:error, message} = Tools.edit(%{args | "path" => "missing.txt"}, ctx)
    assert message =~ "edit read failed"
    refute File.exists?(Path.join(dir, "missing.txt"))
    assert {:error, message} = Tools.edit(%{args | "path" => "."}, ctx)
    assert message =~ "edit read failed"
  end

  test "the public session uses the new edit descriptor and changes every occurrence", %{dir: dir} do
    alias Elara.Message
    File.write!(Path.join(dir, "session.txt"), "old\r\nold")

    call = %Message.ToolCall{
      id: "replace",
      name: "edit",
      args:
        {:ok,
         %{
           "path" => "session.txt",
           "old_text" => "old",
           "new_text" => "new",
           "replace_all" => true
         }}
    }

    {:ok, queue} =
      Agent.start_link(fn ->
        [
          {:ok, %Message.Assistant{tool_calls: [call]}},
          {:ok, %Message.Assistant{text: "done"}}
        ]
      end)

    {:ok, session} =
      Elara.start_session(
        cwd: dir,
        home: dir,
        skill_paths: [],
        plugins: [],
        persist: false,
        tools: Enum.filter(Tool.builtins(), &(&1.name == "edit")),
        provider: {Elara.Provider.Scripted, queue}
      )

    {:ok, pid} = Elara.session_pid(session)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert {:ok, "done"} = Elara.ask(session, "replace every occurrence")
    assert File.read!(Path.join(dir, "session.txt")) == "new\r\nnew"

    assert [%Message.ToolResult{outcome: {:ok, "edited session.txt"}}] =
             Enum.filter(Elara.transcript(session), &is_struct(&1, Message.ToolResult))
  end
end
