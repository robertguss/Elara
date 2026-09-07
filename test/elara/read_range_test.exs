defmodule Elara.ReadRangeTest do
  use ExUnit.Case, async: true

  alias Elara.Tool
  alias Elara.Tool.Ctx
  alias Elara.Tools

  setup do
    dir = Path.join(System.tmp_dir!(), "elara-read-range-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{ctx: %Ctx{cwd: dir}, dir: dir}
  end

  test "path-only read preserves whole-file behavior exactly", %{ctx: ctx, dir: dir} do
    content = "one\r\ntwo\n三\nunterminated"
    File.write!(Path.join(dir, "mixed.txt"), content)

    assert Tools.read(%{"path" => "mixed.txt"}, ctx) == {:ok, content}
  end

  test "reads up to limit lines starting at one-based offset preserving bytes", %{
    ctx: ctx,
    dir: dir
  } do
    content = "one\r\ntwo\n三\r\nfour\nunterminated"
    File.write!(Path.join(dir, "mixed.txt"), content)

    assert Tools.read(%{"path" => "mixed.txt", "offset" => 2, "limit" => 3}, ctx) ==
             {:ok, "two\n三\r\nfour\n"}

    assert Tools.read(%{"path" => "mixed.txt", "offset" => 5, "limit" => 3}, ctx) ==
             {:ok, "unterminated"}
  end

  test "offset and limit default only when a range argument is supplied", %{ctx: ctx, dir: dir} do
    content = Enum.map_join(1..205, "", &"line #{&1}\n")
    File.write!(Path.join(dir, "many.txt"), content)

    assert Tools.read(%{"path" => "many.txt", "offset" => 204}, ctx) ==
             {:ok, "line 204\nline 205\n"}

    expected_first_200 = Enum.map_join(1..200, "", &"line #{&1}\n")
    assert Tools.read(%{"path" => "many.txt", "limit" => 200}, ctx) == {:ok, expected_first_200}
    assert Tools.read(%{"path" => "many.txt", "offset" => 1}, ctx) == {:ok, expected_first_200}
    assert Tools.read(%{"path" => "many.txt"}, ctx) == {:ok, content}
  end

  test "empty files and offsets past EOF return empty string", %{ctx: ctx, dir: dir} do
    File.write!(Path.join(dir, "empty.txt"), "")
    File.write!(Path.join(dir, "short.txt"), "one\ntwo")

    assert Tools.read(%{"path" => "empty.txt", "offset" => 1, "limit" => 10}, ctx) == {:ok, ""}
    assert Tools.read(%{"path" => "short.txt", "offset" => 3, "limit" => 10}, ctx) == {:ok, ""}
  end

  test "rejects invalid supplied offset and limit values", %{ctx: ctx, dir: dir} do
    File.write!(Path.join(dir, "file.txt"), "one\n")

    for {field, value} <- [
          {"offset", nil},
          {"offset", "1"},
          {"offset", 1.0},
          {"offset", 0},
          {"offset", -1},
          {"limit", nil},
          {"limit", "1"},
          {"limit", 1.0},
          {"limit", 0},
          {"limit", -1}
        ] do
      assert {:error, _} = Tools.read(%{"path" => "file.txt", field => value}, ctx)
    end
  end

  test "ranged reads preserve file errors and binary bytes", %{ctx: ctx, dir: dir} do
    assert Tools.read(%{"path" => "missing", "limit" => 1}, ctx) ==
             {:error, "read failed: no such file (missing)"}

    assert Tools.read(%{"path" => ".", "offset" => 1}, ctx) ==
             {:error, "read failed: is a directory (.)"}

    File.write!(Path.join(dir, "bytes"), <<0, 255, 10, 13, 10, 254>>)
    assert Tools.read(%{"path" => "bytes", "limit" => 1}, ctx) == {:ok, <<0, 255, 10>>}
    assert Tools.read(%{"path" => "bytes", "offset" => 2}, ctx) == {:ok, <<13, 10, 254>>}
  end

  test "public session executes the model's range arguments", %{dir: dir} do
    File.write!(Path.join(dir, "source.txt"), "skip\r\nselected\r\nlast")

    call = %Elara.Message.ToolCall{
      id: "read-range",
      name: "read",
      args: {:ok, %{"path" => "source.txt", "offset" => 2, "limit" => 1}}
    }

    {:ok, script} =
      Agent.start_link(fn ->
        [
          {:ok, %Elara.Message.Assistant{tool_calls: [call]}},
          {:ok, %Elara.Message.Assistant{text: "done"}}
        ]
      end)

    {:ok, session} =
      Elara.start_session(
        provider: {Elara.Provider.Scripted, script},
        cwd: dir,
        persist: false,
        tools: Enum.filter(Tool.builtins(), &(&1.name == "read")),
        plugins: []
      )

    on_exit(fn ->
      case Elara.session_pid(session) do
        {:ok, pid} -> GenServer.stop(pid)
        _ -> :ok
      end
    end)

    assert {:ok, "done"} = Elara.ask(session, "read the second line")

    assert [%Elara.Message.ToolResult{outcome: {:ok, "selected\r\n"}}] =
             Enum.filter(Elara.transcript(session), &is_struct(&1, Elara.Message.ToolResult))
  end

  test "read tool schema documents optional range fields" do
    read_tool = Enum.find(Tool.builtins(), &(&1.name == "read"))

    assert read_tool.description =~ "offset"
    assert read_tool.description =~ "limit"
    assert read_tool.parameters["properties"]["offset"]["type"] == "integer"
    assert read_tool.parameters["properties"]["limit"]["type"] == "integer"
    assert read_tool.parameters["properties"]["offset"]["minimum"] == 1
    assert read_tool.parameters["properties"]["limit"]["minimum"] == 1
    assert read_tool.parameters["required"] == ["path"]
  end
end
