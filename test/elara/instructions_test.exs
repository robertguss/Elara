defmodule Elara.InstructionsTest do
  use ExUnit.Case, async: false

  alias Elara.Message.{Assistant, ToolCall, ToolResult}
  alias Elara.Prompt

  defmodule InspectProvider do
    @behaviour Elara.Provider
    def chat(agent, request) do
      check = Agent.get_and_update(agent, fn [check | rest] -> {check, rest} end)
      {:ok, check.(request), agent}
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "elara-instructions-#{System.unique_integer([:positive])}")

    cwd = Path.join(root, "repo")
    home = Path.join(root, "home")
    File.mkdir_p!(Path.join(cwd, "nested/deep"))
    File.mkdir_p!(Path.join(cwd, ".git"))
    File.mkdir_p!(home)
    File.write!(Path.join(root, "AGENTS.md"), "ANCESTOR: prefer broad conventions.")
    File.write!(Path.join(cwd, "AGENTS.md"), "ROOT: use project conventions.")
    File.write!(Path.join(cwd, "nested/AGENTS.md"), "NESTED: use local conventions.")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, cwd: cwd, home: home}
  end

  test "ancestor and invocation scope is ordered and siblings stay unloaded", ctx do
    nested = Path.join(ctx.cwd, "nested/deep")
    system = Prompt.system(nested)
    assert {a, _} = :binary.match(system, "ANCESTOR:")
    assert {b, _} = :binary.match(system, "ROOT:")
    assert {c, _} = :binary.match(system, "NESTED:")
    assert a < b and b < c
    assert system =~ "Nearest scoped instructions specialize parent guidance"
    assert system =~ "Explicit user directions take"
    refute Prompt.system(ctx.cwd) =~ "NESTED:"
    assert system =~ "Scope: #{Path.join(ctx.cwd, "nested")} and descendants"
  end

  test "new scoped guidance defers a whole same-scope batch before any write and allows reconsideration",
       ctx do
    path = Path.join(ctx.cwd, "nested/new.txt")

    calls = [
      call("one", "write", %{"path" => "nested/new.txt", "content" => "ok"}),
      call("two", "read", %{"path" => "nested/new.txt"})
    ]

    session =
      session(ctx, [
        fn request ->
          assert request.system =~ "ROOT:"
          refute request.system =~ "NESTED:"
          %Assistant{tool_calls: calls}
        end,
        fn request ->
          refute File.exists?(path)
          assert request.system =~ "NESTED:"
          results = Enum.filter(request.messages, &is_struct(&1, ToolResult))
          assert length(results) == 2
          assert Enum.all?(results, fn r -> match?({:error, "Not executed:" <> _}, r.outcome) end)

          %Assistant{
            tool_calls: [call("three", "write", %{"path" => "nested/new.txt", "content" => "ok"})]
          }
        end,
        fn request ->
          assert File.read!(path) == "ok"
          assert List.last(request.messages).outcome == {:ok, "wrote 2 bytes to nested/new.txt"}
          %Assistant{text: "done"}
        end
      ])

    assert {:ok, "done"} = Elara.ask(session, "Write the nested file")
    assert Elara.status(session).instructions[Path.join(ctx.cwd, "nested/AGENTS.md")]
    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(session))
  end

  test "explicit user override is preserved and instruction changes refresh between turns", ctx do
    session =
      session(ctx, [
        fn request ->
          assert request.system =~ "ROOT:"
          assert List.last(request.messages).text == "Override project style: use tabs"
          assert request.system =~ "precedence over project instructions and skills"
          %Assistant{text: "first"}
        end,
        fn request ->
          assert request.system =~ "ROOT CHANGED"
          refute request.system =~ "ROOT:"
          %Assistant{text: "second"}
        end
      ])

    assert {:ok, "first"} = Elara.ask(session, "Override project style: use tabs")
    File.write!(Path.join(ctx.cwd, "AGENTS.md"), "ROOT CHANGED")
    assert {:ok, "second"} = Elara.ask(session, "Continue")
    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(session))
  end

  test "unreadable instruction file fails a mutation closed", ctx do
    File.rm!(Path.join(ctx.cwd, "nested/AGENTS.md"))
    File.mkdir!(Path.join(ctx.cwd, "nested/AGENTS.md"))

    session =
      session(ctx, [
        fn _ ->
          %Assistant{
            tool_calls: [call("bad", "write", %{"path" => "nested/no.txt", "content" => "no"})]
          }
        end,
        fn request ->
          assert {:error, message} = List.last(request.messages).outcome
          assert message =~ "unreadable project instructions"
          refute File.exists?(Path.join(ctx.cwd, "nested/no.txt"))
          %Assistant{text: "blocked"}
        end
      ])

    assert {:ok, "blocked"} = Elara.ask(session, "Write")
  end

  test "explicit skill use loads only selected instructions and resolves resources through normal tools",
       ctx do
    directory =
      make_skill(ctx, "using-fixtures", "Read references/data.txt then run scripts/check.sh")

    make_skill(ctx, "other-skill", "UNSELECTED BODY")
    File.mkdir_p!(Path.join(directory, "references"))
    File.mkdir_p!(Path.join(directory, "scripts"))
    File.write!(Path.join(directory, "references/data.txt"), "fixture data")
    File.write!(Path.join(directory, "scripts/check.sh"), "printf script-ok")

    session =
      session(ctx, [
        fn request ->
          assert request.system =~ "using-fixtures"
          refute request.system =~ "Read references/data.txt"
          refute request.system =~ "UNSELECTED BODY"
          %Assistant{tool_calls: [call("load", "skill", %{"name" => "using-fixtures"})]}
        end,
        fn request ->
          assert {:ok, text} = List.last(request.messages).outcome
          assert text =~ "Resource base path: #{directory}"
          assert text =~ "Read references/data.txt"
          refute inspect(request) =~ "UNSELECTED BODY"

          %Assistant{
            tool_calls: [
              call("ref", "read", %{"path" => Path.join(directory, "references/data.txt")})
            ]
          }
        end,
        fn request ->
          assert List.last(request.messages).outcome == {:ok, "fixture data"}

          %Assistant{
            tool_calls: [
              call("script", "bash", %{"command" => "sh '#{directory}/scripts/check.sh'"})
            ]
          }
        end,
        fn request ->
          assert List.last(request.messages).outcome == {:ok, "script-ok"}
          %Assistant{text: "skill done"}
        end
      ])

    assert {:ok, "skill done"} = Elara.ask(session, "Use the using-fixtures skill")
    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(session))
  end

  test "skills cannot grant shell or read capabilities, and missing dependencies report ordinary failures",
       ctx do
    make_skill(ctx, "using-fixtures", "Run elara-deliberately-missing-command")

    checks = [
      fn _ -> %Assistant{tool_calls: [call("load", "skill", %{"name" => "using-fixtures"})]} end,
      fn request ->
        assert {:ok, _} = List.last(request.messages).outcome

        %Assistant{
          tool_calls: [
            call("script", "bash", %{"command" => "elara-deliberately-missing-command"})
          ]
        }
      end,
      fn request ->
        assert {:error, message} = List.last(request.messages).outcome
        assert message =~ "permission denied"
        %Assistant{text: "restricted"}
      end
    ]

    restricted = session(ctx, checks, allowed_capabilities: ["filesystem:read"])
    assert {:ok, "restricted"} = Elara.ask(restricted, "Use the skill")

    no_read =
      session(
        ctx,
        [
          hd(checks),
          fn request ->
            assert {:error, "permission denied:" <> _} = List.last(request.messages).outcome
            %Assistant{text: "denied"}
          end
        ],
        allowed_capabilities: []
      )

    assert {:ok, "denied"} = Elara.ask(no_read, "Use the skill")

    missing =
      session(ctx, [
        fn _ ->
          %Assistant{
            tool_calls: [
              call("missing", "bash", %{"command" => "elara-deliberately-missing-command"})
            ]
          }
        end,
        fn request ->
          assert {:error, "exit 127\n" <> _} = List.last(request.messages).outcome
          %Assistant{text: "missing"}
        end
      ])

    assert {:ok, "missing"} = Elara.ask(missing, "Run the prerequisite")
  end

  test "coordinator children resolve guidance and configured skills without copying parent context",
       ctx do
    directory = make_skill(ctx, "using-fixtures", "CHILD BODY")

    parent =
      session(ctx, [], skill_paths: [Path.relative_to(directory, ctx.cwd)], system: "CUSTOM BASE")

    assert Elara.child_config(parent).skill_options[:skill_paths] == [directory]

    {:ok, agent} =
      Agent.start_link(fn ->
        [
          fn request ->
            assert request.system =~ "CUSTOM BASE"
            assert request.system =~ "ROOT:"
            assert request.system =~ "using-fixtures"
            assert length(Regex.scan(~r/ROOT:/, request.system)) == 1
            refute request.system =~ "CHILD BODY"
            %Assistant{text: "child done"}
          end
        ]
      end)

    {:ok, coordinator} =
      Elara.start_coordinator(parent, provider_factory: fn _ -> {InspectProvider, agent} end)

    on_exit(fn -> if Process.alive?(coordinator), do: GenServer.stop(coordinator) end)

    assert {:ok, run} =
             Elara.Coordinator.run(coordinator, :parallel, [%{id: "child", prompt: "Inspect"}])

    assert [%{answer: "child done"}] = run.results
  end

  defp session(ctx, checks, opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> checks end)

    {:ok, id} =
      Elara.start_session(
        Keyword.merge(
          [
            cwd: ctx.cwd,
            home: ctx.home,
            skill_paths: [],
            persist: false,
            plugins: [],
            provider: {InspectProvider, agent}
          ],
          opts
        )
      )

    on_exit(fn ->
      case Elara.session_pid(id) do
        {:ok, pid} -> GenServer.stop(pid)
        _ -> :ok
      end
    end)

    id
  end

  defp make_skill(ctx, name, body) do
    directory = Path.join([ctx.cwd, ".agents/skills", name])
    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, "SKILL.md"),
      "---\nname: #{name}\ndescription: Uses fixtures when testing.\nallowed-tools: Bash\n---\n#{body}\n"
    )

    directory
  end

  defp call(id, name, args), do: %ToolCall{id: id, name: name, args: {:ok, args}}
end
