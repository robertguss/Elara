defmodule Elara.Lab.Scenarios.SessionRecovery do
  @moduledoc """
  LAB-5 bounded recovery pilot. Exactly three normal inputs, A/B/C, are
  accepted. The selected hook is held in its calling task until B and C are
  queued, then released once. Provider faults kill the first answer task.
  The ordinary direct `lab_marker` path (`effect_executor: nil`) kills the
  session after the write and before the hook returns.

  Reopen is paused, uses a distinct simulator id, and submits no new normal
  input. B and C resume only through `resume_inputs/1`. The observer treats
  neither marker bytes nor `:consumed` as completion. A started marker whose
  persisted receipt is `"session restarted"` fails
  `indeterminate_without_receipt`; that is the registered finding, not a
  runtime change.
  """

  @behaviour Elara.Lab

  alias Elara.Lab.{Jobs, Tools}
  alias Elara.Lab.Scenarios.SessionRecovery.{Gate, Observer, StorePath}
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
  alias Elara.Provider.Simulated

  @faults ~w(provider_started provider_streaming tool_running)
  @labels ["A", "B", "C"]
  @hook "session-recovery"
  @simulator "recovery"
  @reopen_simulator "recovery-reopen"
  @recovery_bound_ms 5_000
  @work_allowance_ms 1_000
  @marks "marks.txt"

  @impl true
  def curve_fields do
    [
      {"recovery_ms", ["recovery_ms"]},
      {"backlog_ms", ["backlog_ms"]},
      {"marker_count", ["marker_count"]}
    ]
  end

  @impl true
  def run(%{provider: :real}), do: raise("session_recovery runs on the simulated provider only")

  def run(%{seed: seed, dir: dir} = context) do
    params = Map.get(context, :params, %{})

    case parse_fault(params["fault"]) do
      {:ok, fault} -> exercise(fault, seed, dir)
      :error -> unknown(dir)
    end
  end

  defp exercise(fault, seed, dir) do
    cwd = Path.join(dir, "workspace")
    File.mkdir_p!(cwd)
    log = Elara.Lab.choice_log()
    {:ok, gate} = Gate.start(fault)
    Tools.register_hook(@hook, Gate.hook(gate))

    try do
      provider = provider(seed, @simulator, log, fault, gate)
      opts = session_opts(cwd, provider)

      case Elara.start_session(opts) do
        {:ok, session} ->
          run_session(fault, seed, cwd, log, gate, opts, session)

        {:error, reason} ->
          incomplete("session_start_failed", reason, fault)
      end
    after
      Tools.unregister_hook(@hook)
      Gate.stop(gate)
      if Process.alive?(log), do: Elara.Lab.choices(log)
    end
  end

  defp run_session(fault, seed, cwd, log, gate, opts, session) do
    {:ok, pid} = Elara.session_pid(session)
    ref = Process.monitor(pid)
    :ok = Elara.subscribe(session)
    accepted = submit_all(session)
    Gate.witness_backlog(gate, session, accepted)

    case fault do
      :tool_running -> session_case(seed, cwd, log, gate, opts, session, pid, ref, accepted)
      point -> provider_case(point, cwd, gate, session, pid, ref, accepted)
    end
  end

  defp provider_case(point, cwd, gate, session, pid, ref, accepted) do
    origin = await_provider_death(gate, pid)
    Process.demonitor(ref, [:flush])
    recovery_ms = await_failed(session, accepted["A"].id, origin.at)
    backlog = await_backlog(session, accepted, origin.at, 2)
    probe = probe(session)

    witness =
      witness(point, cwd, session, accepted, origin, recovery_ms, backlog, probe, gate, nil)

    stop = stop_session(session)
    Observer.report(witness, stop)
  end

  defp session_case(seed, cwd, log, gate, _opts, session, pid, ref, accepted) do
    origin = await_down(ref, pid, gate)
    Gate.hold_until_down(gate, origin.down)
    info = StorePath.find(cwd, session)
    reopen_at = Jobs.now()

    {:ok, reopened} =
      Elara.start_session(
        session_opts(cwd, provider(seed, @reopen_simulator, log, nil, gate)) ++
          [resume: info.path, pause_inputs: true]
      )

    probe = probe_paused(reopened, reopen_at)
    recovery_ms = await_failed(reopened, accepted["A"].id, origin.at)
    paused_inputs = new_normal_inputs(reopened, accepted)
    resume_at = Jobs.now()
    :ok = Elara.resume_inputs(reopened)
    backlog = await_backlog(reopened, accepted, resume_at, 2)

    witness =
      witness(
        :tool_running,
        cwd,
        reopened,
        accepted,
        origin,
        recovery_ms,
        backlog,
        probe,
        gate,
        paused_inputs
      )

    stop = stop_session(reopened)
    Observer.report(witness, stop)
  end

  defp submit_all(session) do
    Map.new(@labels, fn label ->
      id = "recovery-#{label}"
      text = "input #{label}"
      user = %User{text: text}

      {:ok, entry} =
        Elara.submit_input(session, %{id: id, sender_id: "lab", kind: :normal, user: user})

      {label, %{id: entry.id, label: label, text: text}}
    end)
  end

  defp await_provider_death(gate, session_pid) do
    started = Jobs.now()
    deadline = started + @recovery_bound_ms
    note_calling_task(gate, deadline)

    receive do
      {:lab_fault, key, point, :task} ->
        task = Agent.get(gate, & &1.calling_task)
        Agent.update(gate, &%{&1 | provider_fault: {key, point, :task}})
        _death = await_monitored_task(task)
        at = System.monotonic_time(:millisecond)
        %{down: true, reason: :killed, fault_seen: true, at: at, started: started}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        %{
          down: not Process.alive?(session_pid),
          reason: :timeout,
          fault_seen: false,
          at: started
        }
    end
  end

  defp note_calling_task(gate, deadline) do
    receive do
      {:recovery_calling_task, task} when is_pid(task) ->
        Agent.update(gate, &%{&1 | calling_task: task})
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> :timeout
    end
  end

  defp await_monitored_task(task) when is_pid(task) do
    if Process.alive?(task) do
      ref = Process.monitor(task)

      receive do
        {:DOWN, ^ref, :process, ^task, reason} ->
          %{down: true, reason: reason, fault_seen: true, at: Jobs.now()}
      after
        @recovery_bound_ms ->
          %{down: not Process.alive?(task), reason: :timeout, fault_seen: true, at: Jobs.now()}
      end
    else
      %{down: true, reason: :killed, fault_seen: true, at: Jobs.now()}
    end
  end

  defp await_monitored_task(_missing) do
    %{down: false, reason: :no_calling_task, fault_seen: true}
  end

  defp await_down(ref, pid, gate) do
    started = Jobs.now()

    down =
      receive do
        {:DOWN, ^ref, :process, ^pid, reason} -> %{down: true, reason: reason}
      after
        @recovery_bound_ms ->
          %{
            down: not Process.alive?(pid),
            reason: if(Process.alive?(pid), do: :alive, else: :killed)
          }
      end

    %{
      down: down.down and not Process.alive?(pid),
      reason: down.reason,
      fault_seen: Gate.fault_seen?(gate),
      at: if(down.down, do: Jobs.now(), else: started)
    }
  end

  defp await_failed(session, id, origin) do
    deadline = origin + @recovery_bound_ms

    poll(
      fn ->
        match?(
          {:ok, %{state: :failed, error: error}} when is_binary(error),
          Elara.input_status(session, id)
        )
      end,
      deadline
    )

    if Jobs.now() <= deadline, do: Jobs.now() - origin, else: nil
  end

  defp await_backlog(session, accepted, origin, count) do
    deadline = origin + @recovery_bound_ms + count * @work_allowance_ms

    settled? = fn ->
      Enum.all?(["B", "C"], fn label ->
        match?(
          {:ok, %{state: :consumed, error: nil}},
          Elara.input_status(session, accepted[label].id)
        ) and
          answer_settled?(Elara.transcript(session), accepted[label])
      end) and active_id(session) == nil
    end

    poll(settled?, deadline)
    %{ms: Jobs.now() - origin, count: count, settled: settled?.()}
  end

  defp probe(session) do
    started = Jobs.now()

    try do
      if is_map(Elara.status(session)) and Jobs.now() - started <= 1_000, do: :ok, else: :timeout
    catch
      :exit, _ -> :timeout
    end
  end

  defp probe_paused(session, origin) do
    status = probe(session)
    paused = snapshot_inbox(session)["paused"] == true

    if status == :ok and paused and Jobs.now() - origin <= @recovery_bound_ms,
      do: :ok,
      else: :timeout
  end

  defp witness(
         fault,
         cwd,
         session,
         accepted,
         origin,
         recovery_ms,
         backlog,
         probe,
         gate,
         paused_inputs
       ) do
    history = Elara.transcript(session)
    active = active_id(session)

    inputs =
      Map.new(accepted, fn {label, entry} ->
        {:ok, receipt} = Elara.input_status(session, entry.id)

        {label,
         %{
           accepted_id: entry.id,
           user_message_id: entry.id,
           call_id: call_id(history, label),
           label: label,
           receipt: %{state: receipt.state, error: receipt.error},
           active_cleared: active == nil
         }}
      end)

    %{
      fault: fault,
      fault_seen: origin.fault_seen,
      target_down: origin.down,
      inputs: inputs,
      history: encode_history(history),
      marker_labels: logical_labels(history),
      marker_bytes: read_markers(cwd),
      probe: probe,
      recovery_ms: recovery_ms,
      backlog_ms: backlog.ms,
      backlog_count: backlog.count,
      backlog_settled: backlog.settled,
      paused_inputs: paused_inputs,
      hook_returned_before_down: Gate.returned_before_down?(gate),
      active_input_id: active,
      one_shot: Gate.one_shot?(gate)
    }
  end

  defp provider(seed, id, log, fault, gate) do
    schedule =
      if fault in [:provider_started, :provider_streaming],
        do: %{{"#{@simulator}:1", fault} => :task},
        else: %{}

    Simulated.new(
      seed: seed,
      id: id,
      profile: profile(fault),
      collector: log,
      fault: Gate.provider_hook(gate, schedule, fault)
    )
  end

  # Provider faults kill A's first answer request, so A must stream rather than
  # call the marker. A tool-call response never reaches :provider_streaming.
  defp profile(fault) do
    labels =
      if fault in [:provider_started, :provider_streaming], do: ["B", "C"], else: @labels

    [
      ttft_ms: 10,
      deltas_per_sec: 100,
      delta_bytes: 8,
      answer_deltas: 2,
      tool_rounds: 0,
      rules: Enum.map(labels, &marker_rule/1)
    ]
  end

  defp marker_rule(label) do
    {fn messages ->
       match?(%User{text: "input " <> ^label, agent_source: nil}, List.last(messages))
     end, {:tool, "lab_marker", marker_args(label)}}
  end

  defp marker_args(label) do
    %{"path" => @marks, "label" => label, "hook" => @hook, "key" => "label:#{label}"}
  end

  defp session_opts(cwd, provider) do
    [
      cwd: cwd,
      home: cwd,
      skill_paths: [],
      plugins: [],
      tools: [Tools.marker()],
      persist: true,
      max_iterations: 3,
      provider: provider
    ]
  end

  defp call_id(history, label) do
    Enum.find_value(history, fn
      %Assistant{tool_calls: calls} ->
        Enum.find_value(calls, fn
          %ToolCall{id: id, name: "lab_marker", args: {:ok, %{"label" => ^label}}} -> id
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  defp encode_history(history) do
    Enum.map(history, fn
      %User{text: text} ->
        %{"kind" => "user", "text" => text}

      %Assistant{text: text, tool_calls: calls} ->
        %{
          "kind" => "assistant",
          "text" => text,
          "tool_calls" =>
            Enum.map(calls, fn %ToolCall{id: id, name: name, args: args} ->
              %{"id" => id, "name" => name, "args" => encode_args(args)}
            end)
        }

      %ToolResult{call_id: id, name: name, outcome: outcome} ->
        %{
          "kind" => "tool_result",
          "call_id" => id,
          "name" => name,
          "outcome" => encode_outcome(outcome)
        }
    end)
  end

  defp encode_args({:ok, args}), do: args
  defp encode_args({:malformed, text}), do: %{"malformed" => text}
  defp encode_outcome({kind, text}), do: %{"kind" => Atom.to_string(kind), "text" => text}

  defp logical_labels(history) do
    Enum.flat_map(history, fn
      %Assistant{tool_calls: calls} ->
        Enum.flat_map(calls, fn
          %ToolCall{name: "lab_marker", args: {:ok, %{"label" => label}}} -> [label]
          _ -> []
        end)

      _ ->
        []
    end)
  end

  defp answer_settled?(history, entry) do
    id = call_id(history, entry.label)

    Enum.any?(history, fn
      %ToolResult{call_id: ^id, outcome: {:ok, "marked " <> label}} -> label == entry.label
      _ -> false
    end) and id != nil
  end

  defp active_id(session) do
    case Elara.snapshot(session) do
      %{snapshot: %{"inbox" => %{"active_input_id" => id}}} -> id
      _ -> nil
    end
  end

  defp snapshot_inbox(session) do
    case Elara.snapshot(session) do
      %{snapshot: %{"inbox" => inbox}} when is_map(inbox) -> inbox
      _ -> %{}
    end
  end

  defp new_normal_inputs(session, accepted) do
    known = accepted |> Map.values() |> Enum.map(& &1.id) |> MapSet.new()

    snapshot_inbox(session)
    |> Map.get("entries", [])
    |> Enum.count(&(not MapSet.member?(known, &1["id"])))
  end

  defp read_markers(cwd) do
    path = Path.join(cwd, @marks)

    if File.exists?(path), do: path |> File.read!() |> String.split("\n", trim: true), else: []
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        :ok

      Jobs.now() >= deadline ->
        :timeout

      true ->
        Process.sleep(20)
        poll(fun, deadline)
    end
  end

  defp stop_session(session) do
    case Elara.session_pid(session) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Jobs.stop_session(session)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> true
        after
          2_000 -> Process.alive?(pid) == false
        end

      _ ->
        true
    end
  end

  defp parse_fault(name) when name in @faults, do: {:ok, String.to_existing_atom(name)}
  defp parse_fault(_), do: :error

  defp unknown(dir) do
    %{
      checks: %{known_fault: false},
      bounds: %{"recovery" => "undetermined", "backlog" => "undetermined"},
      incomplete: "unknown_fault",
      complete: false,
      cleanup_confirmed: true,
      completed_turns: 0,
      choices_digest: Elara.Lab.digest({:unknown_fault, dir}),
      recovery_ms: nil,
      backlog_ms: nil,
      marker_count: 0,
      recovery: %{accepted_ids: [], receipts: %{}, history_count: 0, marker_bytes: []}
    }
  end

  defp incomplete(reason, detail, fault) do
    %{
      checks: %{known_fault: true, session_started: false},
      bounds: %{"recovery" => "undetermined", "backlog" => "undetermined"},
      incomplete: "#{reason}: #{inspect(detail)}",
      complete: false,
      cleanup_confirmed: true,
      completed_turns: 0,
      choices_digest: Elara.Lab.digest({reason, fault}),
      recovery_ms: nil,
      backlog_ms: nil,
      marker_count: 0,
      fault: Atom.to_string(fault),
      recovery: %{accepted_ids: [], receipts: %{}, history_count: 0, marker_bytes: []}
    }
  end
end

defmodule Elara.Lab.Scenarios.SessionRecovery.Gate do
  @moduledoc false

  def start(fault) do
    Agent.start_link(fn ->
      %{
        fault: fault,
        release: false,
        arrived: %{},
        injections: 0,
        returned_before_down: false,
        backlog: [],
        provider_fault: nil,
        calling_task: nil,
        task_down: false,
        task_down_at: nil
      }
    end)
  end

  def stop(gate) do
    if Process.alive?(gate), do: Agent.stop(gate)
    :ok
  end

  # Only the marker fault holds the calling task. Provider faults must not block
  # the marker hook; their injection is the provider task kill, not this hook.
  def hook(gate) do
    fn :tool_running, key ->
      if state_fault(gate) == :tool_running and marker_label(key) == "A" do
        me = self()
        label = marker_label(key)

        Agent.update(gate, fn state ->
          %{state | arrived: Map.put(state.arrived || %{}, label, {key, me})}
        end)

        send(gate_waiter(gate), :check)

        receive do
          :release ->
            count =
              Agent.get_and_update(gate, fn state ->
                {state.injections, %{state | injections: state.injections + 1}}
              end)

            if count == 0 do
              Elara.Lab.Faults.inject(:session)
              confirm_down(gate)
            end

            :ok
        after
          10_000 -> :ok
        end
      else
        :ok
      end
    end
  end

  def witness_backlog(gate, session, accepted) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    wait = fn wait ->
      queued? =
        Enum.all?(["B", "C"], fn label ->
          match?(
            {:ok, %{state: state}} when state in [:queued, :accepted],
            Elara.input_status(session, accepted[label].id)
          )
        end)

      cond do
        queued? ->
          Agent.update(
            gate,
            &%{&1 | backlog: [accepted["B"].id, accepted["C"].id], release: true}
          )

          send(gate_waiter(gate), :check)
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          :timeout

        true ->
          Process.sleep(20)
          wait.(wait)
      end
    end

    wait.(wait)
  end

  def hold_until_down(gate, down?) do
    Agent.update(gate, fn state ->
      returned = match?({_, pid} when is_pid(pid), state.arrived["A"]) and not down?
      %{state | returned_before_down: returned}
    end)
  end

  defp confirm_down(gate) do
    session =
      (Process.get(:"$callers") || [])
      |> Enum.find(&(Registry.keys(Elara.Sessions, &1) != []))

    deadline = System.monotonic_time(:millisecond) + 5_000

    wait = fn wait ->
      cond do
        is_nil(session) or not Process.alive?(session) ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          Agent.update(gate, &%{&1 | returned_before_down: true})

        true ->
          Process.sleep(10)
          wait.(wait)
      end
    end

    wait.(wait)
  end

  defp marker_label("label:" <> label), do: label
  defp marker_label(key), do: key

  # `self()` inside the wrapper is the calling provider task. Record it before
  # Faults kills it. The scenario process receives the firing notice.
  def provider_hook(_gate, schedule, fault) do
    owner = self()
    inner = Elara.Lab.Faults.hook(schedule, owner)

    fn point, key ->
      if fault in [:provider_started, :provider_streaming] and point == fault do
        send(owner, {:recovery_calling_task, self()})
      end

      inner.(point, key)
    end
  end

  def note_firing(gate, {:lab_fault, key, point, target}) do
    calling = Agent.get(gate, & &1.calling_task)
    Agent.update(gate, &%{&1 | provider_fault: {key, point, target}})
    if target == :task and is_pid(calling), do: watch_task(gate, calling)
    :ok
  end

  defp watch_task(gate, caller) do
    spawn(fn ->
      ref = Process.monitor(caller)

      receive do
        {:DOWN, ^ref, :process, ^caller, reason} ->
          Agent.update(gate, fn state ->
            %{
              state
              | task_down: true,
                task_reason: reason,
                task_down_at: System.monotonic_time(:millisecond)
            }
          end)
      after
        5_000 ->
          Agent.update(gate, fn state ->
            %{
              state
              | task_down: not Process.alive?(caller),
                task_reason: :timeout,
                task_down_at: System.monotonic_time(:millisecond)
            }
          end)
      end
    end)
  end

  def await_task_death(gate, session_pid) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    wait = fn wait ->
      state = Agent.get(gate, & &1)

      cond do
        state.task_down ->
          %{down: true, reason: :killed, fault_seen: true, at: state.task_down_at}

        System.monotonic_time(:millisecond) >= deadline ->
          alive? = Process.alive?(session_pid)

          %{
            down: not alive?,
            reason: if(alive?, do: :alive, else: :killed),
            fault_seen: fault_seen?(gate),
            at: System.monotonic_time(:millisecond)
          }

        true ->
          Process.sleep(20)
          wait.(wait)
      end
    end

    wait.(wait)
  end

  def fault_seen?(gate) do
    Agent.get(gate, fn state ->
      state.injections > 0 or match?({_key, _point, _target}, state[:provider_fault])
    end)
  end

  def returned_before_down?(gate), do: Agent.get(gate, & &1.returned_before_down)
  def one_shot?(gate), do: Agent.get(gate, &(&1.injections <= 1 and map_size_fault(&1) <= 1))

  defp map_size_fault(%{provider_fault: nil}), do: 0
  defp map_size_fault(%{provider_fault: _}), do: 1

  defp state_fault(gate), do: Agent.get(gate, & &1.fault)

  defp gate_waiter(gate) do
    case Process.get({:recovery_gate_waiter, gate}) do
      pid when is_pid(pid) ->
        pid

      _ ->
        parent = self()

        pid =
          spawn_link(fn ->
            loop = fn loop ->
              state = Agent.get(gate, & &1)

              if state.release and state.injections == 0 and
                   match?({_key, hook} when is_pid(hook), state.arrived["A"]) do
                {_key, hook} = state.arrived["A"]
                send(hook, :release)
                send(parent, {:gate_released, gate})
              else
                receive do
                  :check -> loop.(loop)
                after
                  5_000 -> :ok
                end
              end
            end

            loop.(loop)
          end)

        Process.put({:recovery_gate_waiter, gate}, pid)
        pid
    end
  end
end

defmodule Elara.Lab.Scenarios.SessionRecovery.StorePath do
  @moduledoc false

  def find(cwd, session) do
    case Elara.list_sessions(cwd) do
      infos when is_list(infos) ->
        Enum.find(infos, &(&1.id == session)) || %{path: nil}

      _ ->
        %{path: nil}
    end
  end
end

defmodule Elara.Lab.Scenarios.SessionRecovery.Observer do
  @moduledoc """
  Rejects a witness that lacks the fault, the target death, unique accepted
  ids, stable labels, matching history, a settled receipt, or a live probe.
  `:consumed` is not terminal. Marker bytes are not causal completion proof.
  """

  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}

  @labels ["A", "B", "C"]

  def judge(witness) do
    ids = Enum.map(@labels, &witness.inputs[&1].accepted_id)

    checks = %{
      known_fault: witness.fault in [:provider_started, :provider_streaming, :tool_running],
      fault_witnessed: witness.fault_seen == true,
      target_down_witnessed: witness.target_down == true,
      unique_accepted_inputs: length(Enum.uniq(ids)) == 3 and Enum.all?(ids, &is_binary/1),
      backlog_witnessed_before_release: witness.backlog_count == 2,
      one_shot_gate: Map.get(witness, :one_shot, true) == true and witness.fault_seen == true,
      stable_labels: witness.marker_labels == expected_labels(witness.fault),
      exact_identities: exact?(witness.inputs),
      settled_receipts:
        Enum.all?(@labels, &settled?(witness.fault, &1, witness.inputs[&1].receipt)),
      active_input_cleared:
        witness.active_input_id == nil and Enum.all?(witness.inputs, &elem(&1, 1).active_cleared),
      history_identity: history_identity?(witness),
      no_unexpected_labels: unexpected(witness) == [],
      backlog_completed: Map.get(witness, :backlog_settled, true) and backlog?(witness),
      responsive_probe: witness.probe == :ok,
      timing_bounded: timing?(witness),
      indeterminate_without_receipt: indeterminate?(witness),
      no_input_while_paused: witness.paused_inputs in [nil, 0],
      marker_hook_blocked_until_down: witness.hook_returned_before_down != true
    }

    %{
      checks: checks,
      cleanup_confirmed: Map.get(witness, :cleanup_confirmed, true),
      recovery_ms: witness.recovery_ms,
      backlog_ms: witness.backlog_ms,
      history: witness.history,
      recovery: recovery(witness, ids)
    }
  end

  def report(witness, cleanup) do
    judged = judge(Map.put(witness, :cleanup_confirmed, cleanup))

    judged
    |> Map.merge(%{
      choices_digest: Elara.Lab.digest(digest_term(witness)),
      completed_turns:
        Enum.count(
          witness.history,
          &(match?(%{"kind" => "assistant", "tool_calls" => []}, &1) and is_binary(&1["text"]))
        ),
      bounds: %{
        "recovery" => if(judged.checks.timing_bounded, do: "holds", else: "fails"),
        "backlog" =>
          if(judged.checks.backlog_completed and judged.checks.timing_bounded,
            do: "holds",
            else: "fails"
          )
      },
      incomplete: if(judged.checks.responsive_probe, do: nil, else: "unresponsive_probe"),
      complete: judged.checks.responsive_probe,
      marker_count: length(witness.marker_bytes),
      fault: Atom.to_string(witness.fault)
    })
  end

  defp recovery(witness, ids) do
    %{
      accepted_ids: ids,
      receipts: Map.new(witness.inputs, fn {label, input} -> {label, input.receipt} end),
      history_count: length(witness.history),
      marker_bytes: witness.marker_bytes,
      marker_labels: witness.marker_labels,
      fault: witness.fault,
      timing: %{
        recovery_ms: witness.recovery_ms,
        backlog_ms: witness.backlog_ms,
        origin: if(witness.fault == :tool_running, do: "explicit_resume", else: "target_down")
      }
    }
  end

  defp digest_term(witness) do
    {witness.fault,
     witness.inputs |> Map.new(fn {label, input} -> {label, input.accepted_id} end),
     witness.marker_labels}
  end

  defp label_index("A"), do: 0
  defp label_index("B"), do: 1
  defp label_index("C"), do: 2

  defp expected_labels(:tool_running), do: @labels
  defp expected_labels(_fault), do: ["B", "C"]

  defp exact?(inputs) do
    Enum.all?(inputs, fn {label, input} ->
      input.accepted_id == input.user_message_id and (label == "A" or is_binary(input.call_id))
    end)
  end

  defp settled?(_fault, "A", %{state: :failed, error: error}) when is_binary(error), do: true
  defp settled?(_fault, label, %{state: :consumed, error: nil}) when label in ["B", "C"], do: true
  defp settled?(_, _, _), do: false

  defp history_identity?(witness) do
    users = Enum.filter(witness.history, &(&1["kind"] == "user"))

    Enum.all?(witness.inputs, fn {label, input} ->
      user? = Enum.at(users, label_index(label))["text"] == "input #{label}"
      call? = label == "A" or call?(witness.history, input)

      result? =
        case input.receipt do
          %{state: :consumed} ->
            Enum.any?(witness.history, fn
              %{
                "kind" => "tool_result",
                "call_id" => id,
                "outcome" => %{"kind" => "ok", "text" => text}
              } ->
                id == input.call_id and text == "marked #{label}"

              _ ->
                false
            end)

          %{state: :failed} ->
            not Enum.any?(witness.history, fn
              %{"kind" => "tool_result", "call_id" => id, "outcome" => %{"kind" => "ok"}} ->
                id == input.call_id

              _ ->
                false
            end)

          _ ->
            false
        end

      user? and call? and result?
    end)
  end

  defp call?(history, input) do
    Enum.any?(history, fn
      %{"kind" => "assistant", "tool_calls" => calls} ->
        Enum.any?(calls, fn
          %{"id" => id, "name" => "lab_marker", "args" => %{"label" => label}} ->
            id == input.call_id and label == input.label

          _ ->
            false
        end)

      _ ->
        false
    end)
  end

  defp unexpected(witness) do
    expected = MapSet.new(expected_labels(witness.fault))

    witness.marker_labels
    |> Enum.frequencies()
    |> Enum.reject(fn {label, count} -> count == 1 and MapSet.member?(expected, label) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp backlog?(witness) do
    Enum.all?(["B", "C"], fn label ->
      match?(%{state: :consumed, error: nil}, witness.inputs[label].receipt)
    end)
  end

  defp timing?(witness) do
    limit = 5_000 + witness.backlog_count * 1_000

    is_integer(witness.recovery_ms) and witness.recovery_ms <= 5_000 and
      is_integer(witness.backlog_ms) and
      witness.backlog_ms <= limit
  end

  # A started mutation without a causal receipt must remain indeterminate.
  # The ordinary direct-marker path currently inserts "session restarted"
  # instead, so this check fails closed on that receipt.
  defp indeterminate?(%{fault: :tool_running, inputs: %{"A" => %{receipt: receipt}}}) do
    case receipt do
      %{state: :failed, error: "session restarted"} -> false
      %{error: error} when is_binary(error) -> error =~ "indeterminate"
      _ -> false
    end
  end

  defp indeterminate?(%{inputs: %{"A" => %{receipt: %{state: :failed, error: error}}}})
       when is_binary(error),
       do: true

  defp indeterminate?(_), do: false
end
