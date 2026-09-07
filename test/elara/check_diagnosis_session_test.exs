defmodule Elara.CheckDiagnosisSessionTest do
  use ExUnit.Case, async: false

  alias Elara.Message
  alias Elara.Message.ToolCall

  @plugin Path.expand("../../.elara/plugins/elixir_project.exs", __DIR__)

  defmodule Provider do
    @behaviour Elara.Provider

    def chat(config, request) do
      if request.tools == [] do
        send(config.owner, {:diagnosis_request, self(), request})

        text =
          if config.gated do
            receive do
              {:answer, text} -> text
            end
          else
            Elara.CheckDiagnosisSessionTest.answer(request)
          end

        {:ok, assistant} = Message.assistant(text, [])

        {:ok,
         %{
           assistant
           | response_model: "scripted-diagnosis",
             usage: %{"input_tokens" => 100, "output_tokens" => 40, "total_tokens" => 140}
         }, config}
      else
        {status, value, _script} = Elara.Provider.Scripted.chat(config.script, request)
        {status, value, config}
      end
    end
  end

  setup do
    cwd = Path.join(System.tmp_dir!(), "diagnosis-session-#{System.unique_integer([:positive])}")
    for dir <- ["lib", "test"], do: File.mkdir_p!(Path.join(cwd, dir))

    File.write!(Path.join(cwd, "mix.exs"), """
    defmodule DiagnosisExample.MixProject do
      use Mix.Project
      def project, do: [app: :diagnosis_example, version: "0.1.0"]
    end
    """)

    File.write!(
      Path.join(cwd, "lib/example.ex"),
      "defmodule Example, do: def(answer, do: :wrong)\n"
    )

    File.write!(Path.join(cwd, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(cwd, "test/example_test.exs"), """
    defmodule ExampleTest do
      use ExUnit.Case
      test "answer", do: assert(Example.answer() == :correct)
    end
    """)

    on_exit(fn -> File.rm_rf!(cwd) end)
    previous = Application.get_env(:elara, :sessions_root)
    Application.put_env(:elara, :sessions_root, Path.join(cwd, "sessions"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:elara, :sessions_root, previous),
        else: Application.delete_env(:elara, :sessions_root)
    end)

    %{cwd: cwd}
  end

  @tag timeout: 60_000
  test "real failed check, immutable evidence, one diagnosis, inspection and replay", %{cwd: cwd} do
    {session, script, _pid} = session(cwd)
    run_id = failed_check(session, script)

    File.write!(
      Path.join(cwd, "lib/example.ex"),
      "defmodule Example, do: def(answer, do: :correct)\n"
    )

    assert {:ok, output} = invoke(session, script, "diagnose_check", %{"run_id" => run_id})
    assert {:ok, result} = JSON.decode(output)
    assert result["status"] == "accepted"
    assert result["strategy"] == "direct/v1"
    assert result["run_id"] == run_id
    assert result["provider_calls"] == 1
    assert result["response_model"] == "scripted-diagnosis"

    assert Elara.materialized_view(session)["provider_view"]["usage"]["session_totals"] ==
             result["usage"]

    assert result["result"]["likely_cause"] =~ ":wrong"
    assert Enum.any?(result["citations"], &String.contains?(&1["excerpt"], ":wrong"))

    assert_receive {:diagnosis_request, _, request}
    refute_receive {:diagnosis_request, _, _}
    assert request.tools == []
    assert JSON.decode!(hd(request.messages).text)["id"] == run_id

    assert JSON.decode!(hd(request.messages).text)["commands"] ==
             [["mix", "test", "test/example_test.exs:3"]]

    assert {:ok, manifest} = invoke(session, script, "check_evidence", %{"run_id" => run_id})
    manifest = JSON.decode!(manifest)
    source = Enum.find(manifest["artifacts"], &(&1["name"] == "lib/example.ex"))

    assert {:ok, page} =
             invoke(session, script, "check_evidence", %{
               "run_id" => run_id,
               "artifact_id" => source["id"]
             })

    assert page =~ ":wrong"
    refute page =~ ":correct"

    assert {:error, _} =
             invoke(session, script, "diagnose_check", %{"run_id" => "old-or-fabricated"})

    refute_receive {:diagnosis_request, _, _}

    assert {:ok, %Elara.FlightRecorder.Report{status: :match}} =
             Elara.replay(Elara.recording(session))
  end

  @tag timeout: 60_000
  test "capture preserves clone, fork, resume, and rewind without carrying evidence across history changes",
       %{cwd: cwd} do
    for operation <- [:clone, :fork, :resume, :rewind] do
      {session, script, pid} = session(cwd, false, persist: true)
      run_id = failed_check(session, script)
      first = hd(Elara.user_entries(session)).id

      case operation do
        :clone ->
          assert {:ok, nil, [_ | _]} = Elara.clone_session(session)

        :fork ->
          assert {:ok, "elixir_test", []} = Elara.fork(session, first)

        :rewind ->
          assert {:ok, "elixir_test", []} = Elara.tree(session, first)

        :resume ->
          {:ok, empty} = Elara.Session.Store.save(Elara.Session.Store.new(cwd))
          assert {:ok, []} = Elara.resume(session, empty.path)
      end

      assert {:error, "No captured check." <> _} =
               GenServer.call(pid, {:check_evidence, run_id})
    end
  end

  @tag timeout: 60_000
  test "non-UTF8 check output stays usable in evidence and the persisted tool result", %{cwd: cwd} do
    File.write!(Path.join(cwd, "test/test_helper.exs"), """
    :io.setopts(:standard_io, encoding: :latin1)
    IO.binwrite(<<255>>)
    :io.setopts(:standard_io, encoding: :unicode)
    ExUnit.start()
    """)

    {session, script, pid} = session(cwd, false, persist: true)
    run_id = failed_check(session, script)
    assert {:error, output} = tool_result(session, "elixir_test").outcome
    assert String.valid?(output)
    assert output =~ "�"
    assert {:ok, evidence} = GenServer.call(pid, {:check_evidence, run_id})
    assert evidence["output_encoding_repaired"]
    assert {:ok, _} = Elara.Session.Store.open(:sys.get_state(pid).store.path, cwd)
  end

  @tag timeout: 60_000
  test "cancelling one diagnosis kills its worker, fences late results, and leaves another session usable",
       %{cwd: cwd} do
    {session, script, pid} = session(cwd, true)
    run_id = failed_check(session, script)
    prepare(script, "diagnose_check", %{"run_id" => run_id})
    pending = Task.async(fn -> Elara.ask(session, "Diagnose the captured failure") end)
    assert_receive {:diagnosis_request, worker, request}, 5_000
    monitor = Process.monitor(worker)
    assert {:running_tool, _, _, _, _} = Elara.status(session).phase
    [{ref, _task}] = Map.to_list(:sys.get_state(pid).tasks)

    {other, other_script, _} = session(cwd, true)
    other_run = failed_check(other, other_script)
    prepare(other_script, "diagnose_check", %{"run_id" => other_run})
    other_pending = Task.async(fn -> Elara.ask(other, "Diagnose independently") end)
    assert_receive {:diagnosis_request, other_worker, other_request}, 5_000
    Elara.interrupt(session)
    assert {:error, :interrupted} = Task.await(pending, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    assert Process.alive?(other_worker)
    send(other_worker, {:answer, answer(other_request)})
    assert {:ok, "done"} = Task.await(other_pending, 5_000)
    assert {:ok, other_result} = tool_result(other, "diagnose_check").outcome
    assert JSON.decode!(other_result)["run_id"] == other_run

    send(pid, {ref, {:ok, answer(request)}})
    assert Elara.status(session).phase == :idle

    refute Enum.any?(Elara.transcript(session), fn
             %Message.ToolResult{name: "diagnose_check", outcome: {:ok, _}} -> true
             _ -> false
           end)

    assert [_unused_final_reply] = Agent.get_and_update(script, &{&1, []})
    assert {:ok, _} = invoke(session, script, "check_evidence", %{"run_id" => run_id})
  end

  @tag timeout: 60_000
  test "a failed diagnosis worker leaves the captured check available", %{cwd: cwd} do
    {session, script, pid} = session(cwd, true)
    run_id = failed_check(session, script)
    prepare(script, "diagnose_check", %{"run_id" => run_id})
    pending = Task.async(fn -> Elara.ask(session, "Diagnose") end)
    assert_receive {:diagnosis_request, worker, _}, 5_000
    Process.exit(worker, :kill)
    assert {:ok, "done"} = Task.await(pending, 5_000)
    assert Process.alive?(pid)
    assert {:error, error} = tool_result(session, "diagnose_check").outcome
    assert error =~ "tool crashed"
    assert {:ok, _} = invoke(session, script, "check_evidence", %{"run_id" => run_id})
  end

  @tag timeout: 60_000
  test "captured evidence survives persisted restart and rejects writes from unrelated callers",
       %{cwd: cwd} do
    {session, script, pid} = session(cwd, false, persist: true)
    run_id = failed_check(session, script)
    assert {:ok, diagnosis} = invoke(session, script, "diagnose_check", %{"run_id" => run_id})
    store = :sys.get_state(pid).store
    assert {:error, _} = GenServer.call(pid, {:record_check, store.check_evidence})
    GenServer.stop(pid)
    File.write!(Path.join(cwd, "lib/example.ex"), "changed after session stopped\n")

    {resumed, resumed_script, _pid} = session(cwd, false, resume: store.path, persist: true)

    assert {:ok, manifest} =
             invoke(resumed, resumed_script, "check_evidence", %{"run_id" => run_id})

    source = JSON.decode!(manifest)["artifacts"] |> Enum.find(&(&1["name"] == "lib/example.ex"))

    assert {:ok, page} =
             invoke(resumed, resumed_script, "check_evidence", %{
               "run_id" => run_id,
               "artifact_id" => source["id"]
             })

    assert page =~ ":wrong"
    refute page =~ "changed after session stopped"
    assert Elara.materialized_view(resumed)["usage"] == JSON.decode!(diagnosis)["usage"]
  end

  @tag timeout: 60_000
  test "invalid model output is inspectable and never an accepted diagnosis", %{cwd: cwd} do
    {session, script, _pid} = session(cwd, true)
    run_id = failed_check(session, script)
    prepare(script, "diagnose_check", %{"run_id" => run_id})
    pending = Task.async(fn -> Elara.ask(session, "Diagnose") end)
    assert_receive {:diagnosis_request, worker, _}, 5_000
    send(worker, {:answer, "{\"observed_failure\":\"missing the rest\"}"})
    assert {:ok, "done"} = Task.await(pending, 5_000)
    assert %Message.ToolResult{outcome: {:error, text}} = tool_result(session, "diagnose_check")
    assert JSON.decode!(text)["status"] == "invalid_output"
    assert JSON.decode!(text)["raw_response"] =~ "missing the rest"

    assert Elara.materialized_view(session)["provider_view"]["usage"]["session_totals"] ==
             JSON.decode!(text)["usage"]
  end

  def answer(request) do
    evidence = JSON.decode!(hd(request.messages).text)

    source =
      Enum.find(evidence["artifacts"], &(&1["kind"] == "source")) || hd(evidence["artifacts"])

    JSON.encode!(%{
      "observed_failure" => "The test expected :correct and received :wrong.",
      "likely_cause" => "Example.answer returns :wrong.",
      "supporting_evidence" => [
        %{"artifact_id" => source["id"], "start_line" => 1, "end_line" => 1}
      ],
      "unknowns" => [],
      "next_check" => "Correct the return value and rerun the focused test."
    })
  end

  @tag timeout: 60_000
  test "Rust tool inspector exposes a completed diagnosis", %{cwd: cwd} do
    {session, script, _pid} = session(cwd)
    run_id = failed_check(session, script)
    prepare(script, "diagnose_check", %{"run_id" => run_id})
    assert {:ok, "done"} = Elara.ask(session, "Explain the captured failure")
    assert {:ok, diagnosis} = tool_result(session, "diagnose_check").outcome
    expected_path = Path.join(cwd, "diagnosis.json")
    File.write!(expected_path, diagnosis)
    {:ok, server} = Elara.Server.start_link(port: 0, provider: {Elara.Provider.Scripted, script})
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {output, status} =
      System.cmd(
        System.find_executable("python3"),
        [
          Path.expand("../support/check_diagnosis_pty.py", __DIR__),
          Mix.Tasks.Elara.Tui.binary!(),
          Integer.to_string(Elara.Server.port(server)),
          session,
          expected_path
        ],
        env: [
          {"ELARA_TUI_STATE_DIR", Path.join(cwd, "client")},
          {"ELARA_TUI_APPEARANCE_FILE", Path.join(cwd, "appearance.json")}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "Diagnosis PTY passed"
  end

  defp session(cwd, gated \\ false, opts \\ []) do
    {:ok, script} = Agent.start_link(fn -> [] end)
    provider = {Provider, %{script: script, owner: self(), gated: gated}}

    {:ok, session} =
      Elara.start_session(
        Keyword.merge(
          [
            cwd: cwd,
            home: cwd,
            skill_paths: [],
            plugins: [@plugin],
            provider: provider,
            persist: false
          ],
          opts
        )
      )

    {:ok, pid} = Elara.session_pid(session)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {session, script, pid}
  end

  defp failed_check(session, script) do
    assert {:error, failed} =
             invoke(session, script, "elixir_test", %{
               "target" => "test/example_test.exs:3",
               "evidence_paths" => ["lib/example.ex", "test/example_test.exs"]
             })

    assert failed =~ "evidence_run_id="
    assert {:ok, json} = invoke(session, script, "check_evidence", %{})
    JSON.decode!(json)["id"]
  end

  defp prepare(script, name, args) do
    call = %ToolCall{
      id: "call-#{System.unique_integer([:positive])}",
      name: name,
      args: {:ok, args}
    }

    Agent.update(script, fn [] ->
      [Message.assistant(nil, [call]), Message.assistant("done", [])]
    end)
  end

  defp invoke(session, script, name, args) do
    prepare(script, name, args)
    assert {:ok, "done"} = Elara.ask(session, name)
    tool_result(session, name).outcome
  end

  defp tool_result(session, name) do
    Elara.transcript(session)
    |> Enum.reverse()
    |> Enum.find(&match?(%Message.ToolResult{name: ^name}, &1))
  end
end
