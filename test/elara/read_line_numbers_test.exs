defmodule Elara.ReadLineNumbersTest do
  use ExUnit.Case, async: true

  alias Elara.Tool
  alias Elara.Tool.Ctx
  alias Elara.Tools

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "elara-read-line-numbers-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{ctx: %Ctx{cwd: dir}, dir: dir}
  end

  test "omitted or false line_numbers preserves existing read behavior", %{ctx: ctx, dir: dir} do
    content = "one\r\ntwo\n三\nunterminated"
    File.write!(Path.join(dir, "mixed.txt"), content)

    assert Tools.read(%{"path" => "mixed.txt"}, ctx) == {:ok, content}
    assert Tools.read(%{"path" => "mixed.txt", "line_numbers" => false}, ctx) == {:ok, content}

    assert Tools.read(
             %{"path" => "mixed.txt", "offset" => 2, "limit" => 2, "line_numbers" => false},
             ctx
           ) == {:ok, "two\n三\n"}
  end

  test "numbers the selected original lines while preserving endings and final line", %{
    ctx: ctx,
    dir: dir
  } do
    content = "one\r\ntwo\n\n三\r\nunterminated"
    File.write!(Path.join(dir, "mixed.txt"), content)

    assert Tools.read(
             %{"path" => "mixed.txt", "offset" => 2, "limit" => 4, "line_numbers" => true},
             ctx
           ) == {:ok, "2: two\n3: \n4: 三\r\n5: unterminated"}
  end

  test "line_numbers with no range numbers the entire file without implicit 200 line limit", %{
    ctx: ctx,
    dir: dir
  } do
    content = Enum.map_join(1..205, "", &"line #{&1}\n")
    File.write!(Path.join(dir, "many.txt"), content)

    expected = Enum.map_join(1..205, "", &"#{&1}: line #{&1}\n")
    assert Tools.read(%{"path" => "many.txt", "line_numbers" => true}, ctx) == {:ok, expected}
  end

  test "empty input, offset past EOF, and trailing newline do not create phantom numbered lines",
       %{
         ctx: ctx,
         dir: dir
       } do
    File.write!(Path.join(dir, "empty.txt"), "")
    File.write!(Path.join(dir, "short.txt"), "one\ntwo\n")

    assert Tools.read(%{"path" => "empty.txt", "line_numbers" => true}, ctx) == {:ok, ""}

    assert Tools.read(
             %{"path" => "short.txt", "offset" => 3, "limit" => 10, "line_numbers" => true},
             ctx
           ) == {:ok, ""}

    assert Tools.read(%{"path" => "short.txt", "line_numbers" => true}, ctx) ==
             {:ok, "1: one\n2: two\n"}
  end

  test "line_numbers preserves arbitrary bytes within lines", %{ctx: ctx, dir: dir} do
    File.write!(Path.join(dir, "bytes"), <<0, 255, 10, 13, 10, 254>>)

    assert Tools.read(%{"path" => "bytes", "line_numbers" => true}, ctx) ==
             {:ok, <<"1: ", 0, 255, 10, "2: ", 13, 10, "3: ", 254>>}
  end

  test "rejects nonboolean line_numbers without modifying file", %{ctx: ctx, dir: dir} do
    path = Path.join(dir, "file.txt")
    File.write!(path, "one\n")

    for value <- [nil, "true", 1, 0, []] do
      assert {:error, _} = Tools.read(%{"path" => "file.txt", "line_numbers" => value}, ctx)
      assert File.read!(path) == "one\n"
    end
  end

  test "public read tool schema exposes line_numbers and version 3" do
    read_tool = Enum.find(Tool.builtins(), &(&1.name == "read"))

    assert read_tool.version == "3"
    assert read_tool.parameters["properties"]["line_numbers"]["type"] == "boolean"
    assert read_tool.parameters["required"] == ["path"]
  end
end
