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

  test "a session completes a 1 MiB command and retrieves the middle after reopen and clone", %{
    dir: dir
  } do
    alias Elara.Message.{Assistant, ToolCall, ToolResult}
    contents = Enum.map_join(1..16_384, fn n -> String.pad_trailing("#{n} ", 63, "x") <> "\n" end)
    File.write!(Path.join(dir, "source.txt"), contents)

    {:ok, provider} =
      Agent.start_link(fn ->
        [
          {:ok,
           %Assistant{
             tool_calls: [
               %ToolCall{
                 id: "large",
                 name: "bash",
                 args: {:ok, %{"command" => "cat source.txt; touch finished"}}
               }
             ]
           }},
          {:ok, %Assistant{text: "finished"}}
        ]
      end)

    opts = [provider: {Elara.Provider.Scripted, provider}, cwd: dir, plugins: []]
    {:ok, session} = Elara.start_session(opts)
    assert {:ok, "finished"} = Elara.ask(session, "run")
    assert File.exists?(Path.join(dir, "finished"))

    assert [%ToolResult{outcome: {:ok, preview}}] =
             Enum.filter(Elara.transcript(session), &is_struct(&1, ToolResult))

    assert byte_size(preview) <= 16_384
    assert preview =~ "bytes=1048576; lines=16384; capture=complete"
    assert preview =~ "1 "
    assert preview =~ "16384 "
    refute preview =~ "8193 "
    [_, handle] = Regex.run(~r/\A\[output (out_[A-Za-z0-9_-]+);/, preview)
    args = %{"handle" => handle, "offset" => 8193, "limit" => 1}
    assert {:ok, middle} = Tools.output_read(args, %Ctx{cwd: dir, session_id: session})
    assert middle =~ "8193: " <> String.pad_trailing("8193 ", 63, "x")
    assert middle =~ "offset=8194"
    assert {:error, missing} = Tools.output_read(args, %Ctx{cwd: dir, session_id: "unrelated"})

    assert {:error, ^missing} =
             Tools.output_read(%{args | "handle" => "out_" <> String.duplicate("a", 43)}, %Ctx{
               cwd: dir,
               session_id: session
             })

    assert {:ok, nil, _} = Elara.clone_session(session)
    clone = Enum.find(Elara.Session.Store.list(dir), &(&1.id != session))
    assert {:ok, ^middle} = Tools.output_read(args, %Ctx{cwd: dir, session_id: clone.id})

    Agent.update(provider, fn _ ->
      [
        {:ok,
         %Assistant{
           tool_calls: [
             %ToolCall{id: "read-middle", name: "output_read", args: {:ok, args}},
             %ToolCall{
               id: "new-output",
               name: "bash",
               args: {:ok, %{"command" => "printf aftercopy"}}
             }
           ]
         }},
        {:ok, %Assistant{text: "copied"}}
      ]
    end)

    assert {:ok, "copied"} = Elara.ask(session, "use the copied output and capture another")

    assert Enum.any?(
             Elara.transcript(session),
             &match?(%ToolResult{call_id: "read-middle", outcome: {:ok, ^middle}}, &1)
           )

    %ToolResult{outcome: {:ok, new_output}} =
      Enum.find(Elara.transcript(session), &match?(%ToolResult{call_id: "new-output"}, &1))

    [_, new_handle] = Regex.run(~r/\A\[output (out_[A-Za-z0-9_-]+);/, new_output)

    assert {:ok, child} =
             Elara.Threads.start_child(session, "keep copied evidence",
               history: true,
               pause_inputs: true
             )

    assert {:ok, child_output} =
             Tools.output_read(%{"handle" => new_handle}, %Ctx{cwd: dir, session_id: child["id"]})

    assert child_output =~ "1: aftercopy"
    {:ok, child_pid} = Elara.session_pid(child["id"])
    :ok = GenServer.stop(child_pid)
    {:ok, pid} = Elara.session_pid(session)
    :ok = GenServer.stop(pid)
    assert {:ok, reopened} = Elara.start_session(opts ++ [resume: clone.path])
    assert reopened == clone.id
    assert {:ok, ^middle} = Tools.output_read(args, %Ctx{cwd: dir, session_id: reopened})

    assert {:ok, aftercopy} =
             Tools.output_read(%{"handle" => new_handle}, %Ctx{cwd: dir, session_id: reopened})

    assert aftercopy =~ "1: aftercopy"
  end

  test "content capture supports literal reads across chunks and explicitly clips giant lines", %{
    ctx: ctx
  } do
    ctx = %{ctx | session_id: "output-test-#{System.unique_integer([:positive])}"}
    chunks = ["first\n", String.duplicate("x", 20_000), "needle[", ".]\nlast"]
    assert {:error, preview} = Elara.Output.capture(ctx, {:content, :error, chunks})
    assert byte_size(preview) <= 16_384
    assert preview =~ "bytes=20020; lines=3; capture=complete"
    [_, handle] = Regex.run(~r/\A\[output (out_[A-Za-z0-9_-]+);/, preview)

    assert {:ok, page} =
             Tools.output_read(%{"handle" => handle, "pattern" => "needle[.]", "limit" => 1}, ctx)

    assert page =~ "matching snippet"
    assert page =~ "needle[.]"
    assert page =~ "line clipped"
    assert byte_size(page) <= 16_384

    assert {:ok, last} =
             Tools.output_read(%{"handle" => handle, "offset" => 3, "limit" => 1}, ctx)

    assert last =~ "3: last"
    assert {:error, _} = Tools.output_read(%{"handle" => handle, "limit" => 201}, ctx)
    assert {:error, _} = Tools.output_read(%{"handle" => "../source.txt"}, ctx)

    for padding <- ["", "x"] do
      unicode = padding <> String.duplicate("à", 4000)
      assert {:ok, whole} = Elara.Output.capture(ctx, {:content, :ok, [unicode]})
      assert String.ends_with?(whole, unicode)
    end

    assert {:ok, binary_preview} =
             Elara.Output.capture(
               ctx,
               {:content, :ok, [String.duplicate(<<255>>, 20_000), "TAIL_SENTINEL"]}
             )

    assert String.valid?(binary_preview)
    assert byte_size(binary_preview) <= 16_384
    assert String.ends_with?(binary_preview, "TAIL_SENTINEL")
  end

  test "fork inheritance grants only handles in the copied evidence", %{ctx: ctx, dir: dir} do
    alias Elara.Message
    alias Elara.Session.Store
    source = Store.new(dir)
    ctx = %{ctx | session_id: source.id}
    {:ok, first} = Elara.Output.capture(ctx, {:content, :ok, ["copied\n"]})
    {:ok, second} = Elara.Output.capture(ctx, {:content, :ok, ["not copied\n"]})

    {:ok, source} =
      Store.append(source, %Message.ToolResult{
        call_id: "one",
        name: "bash",
        outcome: {:ok, first}
      })

    {:ok, source} = Store.append(source, Message.user("fork here"))
    fork_at = source.leaf

    {:ok, source} =
      Store.append(source, %Message.ToolResult{
        call_id: "two",
        name: "bash",
        outcome: {:ok, second}
      })

    {:ok, fork, "fork here"} = Store.fork_before_user(source, fork_at)
    [_, first_handle] = Regex.run(~r/\A\[output (out_[A-Za-z0-9_-]+);/, first)
    [_, second_handle] = Regex.run(~r/\A\[output (out_[A-Za-z0-9_-]+);/, second)
    fork_ctx = %{ctx | session_id: fork.id}
    assert {:ok, copied} = Tools.output_read(%{"handle" => first_handle}, fork_ctx)
    assert copied =~ "1: copied"
    assert {:error, _} = Tools.output_read(%{"handle" => second_handle}, fork_ctx)
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
