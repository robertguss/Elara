defmodule Elara.ToolsTest do
  use ExUnit.Case, async: true

  alias Elara.Tool.Ctx
  alias Elara.Tools

  setup do
    dir = Path.join(System.tmp_dir!(), "elara-tools-#{System.unique_integer([:positive])}")
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

  test "file tools refuse protected names and resolved escapes without changing files", %{
    ctx: ctx,
    dir: dir
  } do
    outside = dir <> "-outside"
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    File.write!(Path.join(outside, "secret.txt"), "old")
    File.ln_s!(outside, Path.join(dir, "escape"))

    for path <-
          ~w(.envrc .iex.exs .bashrc .zshrc .git/config .git/hooks/pre-commit nested/.git/config) do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), "old")
    end

    for path <-
          ~w(.envrc .iex.exs .bashrc .zshrc .git/config .git/hooks/pre-commit nested/.git/config escape/secret.txt) ++
            [Path.join(outside, "secret.txt")] do
      assert {:error, message} = Tools.read(%{"path" => path}, ctx)
      assert message =~ "file access refused"
      assert {:error, _} = Tools.write(%{"path" => path, "content" => "new"}, ctx)

      assert {:error, _} =
               Tools.edit(%{"path" => path, "old_text" => "old", "new_text" => "new"}, ctx)

      assert File.read!(Path.expand(path, dir)) == "old"
    end
  end

  test "file tools follow allowed symlinks but protect their destination", %{ctx: ctx, dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), "old")
    File.ln_s!("AGENTS.md", Path.join(dir, "CLAUDE.md"))
    assert {:ok, "old"} = Tools.read(%{"path" => "CLAUDE.md"}, ctx)

    assert {:ok, _} =
             Tools.edit(
               %{"path" => "CLAUDE.md", "old_text" => "old", "new_text" => "edited"},
               ctx
             )

    assert {:ok, _} = Tools.write(%{"path" => "CLAUDE.md", "content" => "written"}, ctx)
    assert File.read!(Path.join(dir, "AGENTS.md")) == "written"
    assert File.read_link!(Path.join(dir, "CLAUDE.md")) == "AGENTS.md"
    File.write!(Path.join(dir, ".envrc"), "protected")
    File.ln_s!(".envrc", Path.join(dir, "innocent.txt"))
    assert {:error, _} = Tools.read(%{"path" => "innocent.txt"}, ctx)
    assert {:error, _} = Tools.write(%{"path" => "innocent.txt", "content" => "new"}, ctx)
    assert File.read!(Path.join(dir, ".envrc")) == "protected"
  end
end
