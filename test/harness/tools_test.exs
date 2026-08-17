defmodule Harness.ToolsTest do
  use ExUnit.Case, async: true

  alias Harness.Tool.Ctx
  alias Harness.Tools

  setup do
    dir = Path.join(System.tmp_dir!(), "harness-tools-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{ctx: %Ctx{cwd: dir}, dir: dir}
  end

  test "read write edit bash", %{ctx: ctx, dir: dir} do
    assert {:error, _} = Tools.read(%{"path" => "missing.txt"}, ctx)

    assert {:ok, msg} = Tools.write(%{"path" => "a.txt", "content" => "hello world"}, ctx)
    assert msg =~ "wrote"
    assert File.read!(Path.join(dir, "a.txt")) == "hello world"

    assert {:ok, "hello world"} = Tools.read(%{"path" => "a.txt"}, ctx)

    assert {:ok, _} =
             Tools.edit(%{"path" => "a.txt", "old_text" => "world", "new_text" => "there"}, ctx)

    assert File.read!(Path.join(dir, "a.txt")) == "hello there"

    assert {:error, _} =
             Tools.edit(%{"path" => "a.txt", "old_text" => "nope", "new_text" => "x"}, ctx)

    assert {:ok, out} = Tools.bash(%{"command" => "printf hi"}, ctx)
    assert out == "hi"

    assert {:error, err} = Tools.bash(%{"command" => "exit 7"}, ctx)
    assert err =~ "exit 7"
  end

  test "edit requires exactly one match", %{ctx: ctx} do
    assert {:ok, _} = Tools.write(%{"path" => "b.txt", "content" => "aa aa"}, ctx)

    assert {:error, msg} =
             Tools.edit(%{"path" => "b.txt", "old_text" => "aa", "new_text" => "b"}, ctx)

    assert msg =~ "2 times"
  end
end
