defmodule Elara.Lab.VMRecoveryPeer do
  @moduledoc "PID-free public session fixture run only inside an owned disposable BEAM."
  alias Elara.Lab.{InputObserver, NativeGroup, VM}
  alias Elara.Lab.Scenarios.VMRecovery
  alias Elara.Effect.ControllerJournal
  alias Elara.Session.Handoff

  def run([root, mode, stage, work_ms, boot_id]) do
    Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))
    Application.put_env(:elara, :skills_home, Path.join(root, "home"))
    Application.put_env(:elara, :max_restarts, 3)
    {:ok, _} = Application.ensure_all_started(:elara)
    {:ok, {flags, _children}} = :sys.get_state(Elara.Supervisor) |> Tuple.to_list() |> List.last()
    %{available: true, jobs: 0, os_pid: stub} = Elara.Exec.status()

    VM.write(root, mode <> "-boot", %{
      os_pid: String.to_integer(System.pid()),
      stub: stub,
      boot_id: boot_id,
      max_restarts: flags.intensity,
      period: flags.period
    })

    config = %{root: root, mode: mode, stage: stage, work_ms: String.to_integer(work_ms)}
    if mode == "prepare", do: prepare(config), else: recover(config)
    if mode == "prepare", do: serve(config), else: Process.sleep(:infinity)
  end

  defp options(config) do
    [
      cwd: Path.join(config.root, "workspace"),
      home: Path.join(config.root, "home"),
      skill_paths: [],
      plugins: [],
      tools: Enum.filter(Elara.Tool.builtins(), &(&1.name == "bash")),
      provider: {Elara.Lab.VMRecoveryProvider, config},
      context_limit: 100_000,
      max_iterations: 3,
      tool_timeout_ms: 60_000,
      max_tool_output_bytes: 1_024
    ]
  end

  defp prepare(config) do
    {:ok, id} = Elara.start_session(options(config))
    {:ok, pid} = Elara.session_pid(id)
    {:ok, store} = Handoff.store(id)
    VM.write(config.root, "source", %{id: id, path: store.path})
    {:ok, _} = Elara.submit_input(id, VMRecovery.normal("A"))

    true =
      VM.wait(
        fn ->
          if config.stage == "provider_running" do
            VM.read(config.root, "provider-point")
          else
            NativeGroup.before(Path.join(config.root, "workspace"))
          end
        end,
        10_000
      ) != nil

    for label <- VM.read(config.root, "schedule")["order"] do
      {:ok, _} = Elara.submit_input(id, VMRecovery.normal(label))
    end

    shell = :sys.get_state(pid)
    point = if config.stage == "provider_running", do: VM.read(config.root, "provider-point")

    native =
      if config.stage == "mutation_running" do
        native = NativeGroup.before(Path.join(config.root, "workspace"))
        epoch = NativeGroup.epoch(native)
        Map.merge(native, %{stub: epoch.os_pid, guardian: epoch.guardian})
      end

    kind = if config.stage == "provider_running", do: :provider, else: :tool

    task =
      Enum.find_value(shell.tasks, fn {_ref, task} ->
        if elem(task, 0) == kind, do: elem(task, 2)
      end)

    true = is_pid(task) and Process.alive?(task)
    {:monitors, monitors} = Process.info(pid, :monitors)
    true = {:process, task} in monitors
    jobs = journal_jobs(shell.effect_journal)

    VM.write(config.root, "checkpoint", %{
      stage: config.stage,
      source_pid: inspect(pid),
      point: point,
      task: inspect(task),
      native: native,
      intent: Enum.map(jobs, &Map.from_struct/1),
      journal_present: shell.effect_journal != nil,
      receipt_backend: shell.effect_executor != nil
    })
  end

  defp serve(config, nonce \\ nil) do
    request = VM.read(config.root, "probe")

    nonce =
      if request != nil and request["nonce"] != nonce do
        %{"id" => id} = VM.read(config.root, "source")
        {:ok, pid} = Elara.session_pid(id)
        shell = :sys.get_state(pid)
        checkpoint = VM.read(config.root, "checkpoint")

        held =
          Enum.any?(shell.tasks, fn {_ref, task} ->
            inspect(elem(task, 2)) == checkpoint["task"] and Process.alive?(elem(task, 2))
          end)

        VM.write(config.root, "eligible", %{
          nonce: request["nonce"],
          held: held,
          active_input_id: shell.store.active_input_id,
          inputs_paused: shell.store.inputs_paused
        })

        request["nonce"]
      else
        nonce
      end

    Process.sleep(10)
    serve(config, nonce)
  end

  defp recover(config) do
    %{"id" => id, "path" => path} = VM.read(config.root, "source")
    began = System.monotonic_time(:millisecond)
    {:ok, ^id} = Elara.start_session(options(config) ++ [resume: path, pause_inputs: true])
    {:ok, view} = InputObserver.read(path, VMRecovery.expected())

    statuses =
      Map.new(~w(A B C), fn label ->
        {:ok, status} = Elara.input_status(id, VMRecovery.normal(label).id)
        {label, Map.take(status, [:id, :state, :error])}
      end)

    VM.write(config.root, "reopened", %{
      recovery_ms: System.monotonic_time(:millisecond) - began,
      view: view,
      statuses: statuses
    })

    true = VM.wait(fn -> File.exists?(Path.join(config.root, "resume")) end, 30_000) == true
    began = System.monotonic_time(:millisecond)
    :ok = Elara.resume_inputs(id)

    view =
      VM.wait(
        fn ->
          case InputObserver.read(path, VMRecovery.expected()) do
            {:ok, %{all_terminal: true} = view} -> view
            _ -> nil
          end
        end,
        5_000 + 2 * config.work_ms
      )

    {:ok, store} = Handoff.store(id)
    {:ok, pid} = Elara.session_pid(id)
    shell = :sys.get_state(pid)
    jobs = journal_jobs(shell.effect_journal)

    VM.write(config.root, "finished", %{
      backlog_ms: System.monotonic_time(:millisecond) - began,
      view: view,
      intent: Enum.map(jobs, &Map.from_struct/1),
      journal_present: shell.effect_journal != nil,
      active_input_id: store.active_input_id,
      exec: Elara.Exec.status()
    })
  end

  defp journal_jobs(nil), do: []

  defp journal_jobs(journal) do
    {:ok, jobs} = ControllerJournal.all(journal)
    jobs
  end
end

defmodule Elara.Lab.VMRecoveryProvider do
  @moduledoc "Stateless, path-configured responses for declared VM recovery inputs."
  @behaviour Elara.Provider
  alias Elara.Lab.{NativeGroup, VM}
  alias Elara.Message.{Assistant, ToolCall, User}

  def chat(config, request) do
    user = Enum.find(Enum.reverse(request.messages), &is_struct(&1, User))
    label = String.replace_prefix(user.text, "vm ", "")
    File.write!(Path.join(config.root, "requests"), label <> "\n", [:append, :sync])
    Process.sleep(config.work_ms)

    answer =
      cond do
        config.mode == "prepare" and label == "A" and config.stage == "provider_running" ->
          VM.write(config.root, "provider-point", %{pid: inspect(self()), input: user.text})

          true =
            VM.wait(
              fn -> File.exists?(Path.join(config.root, "release-provider")) end,
              30_000
            ) == true

          %Assistant{text: "done vm A"}

        config.mode == "prepare" and label == "A" and config.stage == "mutation_running" ->
          %Assistant{
            text: "",
            tool_calls: [
              %ToolCall{
                id: "vm-A",
                name: "bash",
                args: {:ok, %{"command" => NativeGroup.command()}}
              }
            ]
          }

        config.mode == "recover" and label in ["B", "C"] and List.last(request.messages) == user ->
          %Assistant{text: "done vm " <> label}

        true ->
          raise "unknown VM fixture request #{inspect({config.mode, label})}"
      end

    {:ok, answer, config}
  end
end
