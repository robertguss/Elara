alias Elara.Lab.Scenarios.SessionRecovery.{Coordinator, Deadline, Observer, StoreView}
alias Elara.Lab.Jobs
alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
alias Elara.Session.Store

root = Path.join(System.tmp_dir!(), "rob1085-independent-#{System.unique_integer([:positive])}")
File.mkdir_p!(root)
Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))
accepted = Map.new(~w(A B C), &{&1, %{id: "accepted-#{&1}", text: "input #{&1}"}})

reopen = fn s ->
  {:ok, s} = Store.save(s)
  {:ok, s} = Store.open(s.path, root)
  s
end

base =
  Enum.reduce(~w(A B C), Store.new(root), fn label, s ->
    {:ok, s} = Store.append(s, %User{text: "input #{label}"})

    if label == "A" do
      {:ok, s} = Store.append(s, %Assistant{text: "partial", interrupted: true})
      s
    else
      call = %ToolCall{id: "call-#{label}", name: "lab_marker", args: {:ok, %{"label" => label}}}
      {:ok, s} = Store.append(s, %Assistant{tool_calls: [call]})

      {:ok, s} =
        Store.append(s, %ToolResult{
          call_id: call.id,
          name: call.name,
          outcome: {:ok, "marked #{label}"}
        })

      {:ok, s} = Store.append(s, %Assistant{text: "answer #{label}"})
      s
    end
  end)

inbox =
  Enum.with_index(~w(A B C))
  |> Enum.map(fn {label, i} ->
    %{
      id: accepted[label].id,
      session_id: base.id,
      sender_id: "lab",
      kind: :normal,
      state: if(label == "A", do: :failed, else: :consumed),
      error: if(label == "A", do: "provider died", else: nil),
      user: %User{text: "input #{label}"},
      created_at: i
    }
  end)

{:ok, base} = Store.put_inbox(base, inbox, false)
base = reopen.(base)
File.write!(Path.join(root, "marks.txt"), "B\nC\n")

attrs = %{
  accepted: accepted,
  cwd: root,
  fault: :provider_started,
  probe: :ok,
  paused_inputs: nil,
  recovery_ms: 10,
  backlog_ms: 20,
  backlog_count: 2,
  backlog_settled: true,
  marker_bytes: ["B", "C"],
  clocks: %{
    recovery: %{origin: "target_down", origin_at: 5, endpoint_at: 15, ms: 10},
    backlog: %{origin: "target_down", origin_at: 5, endpoint_at: 25, ms: 20}
  }
}

protocol = %{
  fault_seen: true,
  target_down: true,
  one_shot: true,
  hook_returned_before_down: false,
  death: %{matched: true, target: "target", reason: :killed, at: 5},
  ordering: %{
    monitor_installed_at: 1,
    arrived_at: 1,
    backlog_observed_at: 2,
    released_at: 3,
    injected_at: 4,
    target_down_at: 5,
    target: "target",
    backlog_ids: ["accepted-B", "accepted-C"]
  }
}

cleanup = %{confirmed: true, choices: %{}}
witness = fn s -> StoreView.witness(s, attrs) |> Map.merge(protocol) end
report = fn s -> Observer.report(witness.(s), cleanup) end

show = fn label, s ->
  r = report.(s)
  decoded = r |> JSON.encode!() |> JSON.decode!()

  IO.inspect(
    {label, StoreView.settled?(s, accepted), r.complete, r.bounds, Elara.Lab.failed_checks(r),
     decoded["completed_turns"]},
    label: "persisted"
  )
end

rewrite = fn s, f ->
  %{s | entries: Enum.map(s.entries, fn e -> %{e | message: f.(e.message)} end)}
end

receipt = fn s, f ->
  %{s | inbox: Enum.map(s.inbox, fn i -> if i.id == "accepted-B", do: f.(i), else: i end)}
end

insert_before_last = fn s, message ->
  last = List.last(s.entries)
  extra = %{last | id: "extra", message: message}
  %{s | entries: Enum.drop(s.entries, -1) ++ [extra, %{last | parent_id: extra.id}]}
end

mutations = [
  {"reused B/C call IDs",
   fn s ->
     rewrite.(s, fn
       %Assistant{tool_calls: [c]} = m -> %{m | tool_calls: [%{c | id: "shared"}]}
       %ToolResult{} = m -> %{m | call_id: "shared"}
       m -> m
     end)
   end},
  {"empty B call/result ID",
   fn s ->
     rewrite.(s, fn
       %Assistant{tool_calls: [%ToolCall{id: "call-B"} = c]} = m ->
         %{m | tool_calls: [%{c | id: ""}]}

       %ToolResult{call_id: "call-B"} = m ->
         %{m | call_id: ""}

       m ->
         m
     end)
   end},
  {"wrong B inbox user", fn s -> receipt.(s, &%{&1 | user: %User{text: "WRONG"}}) end},
  {"wrong B sender", fn s -> receipt.(s, &%{&1 | sender_id: "wrong"}) end},
  {"wrong B kind", fn s -> receipt.(s, &%{&1 | kind: :steer}) end},
  {"reordered inbox", fn s -> %{s | inbox: Enum.reverse(s.inbox)} end},
  {"extra interrupted C",
   fn s -> insert_before_last.(s, %Assistant{text: "stale", interrupted: true}) end},
  {"extra C terminal", fn s -> insert_before_last.(s, %Assistant{text: "stale"}) end},
  {"leaf before C", fn s -> %{s | leaf: Enum.at(s.entries, 5).id} end},
  {"offbranch C completion",
   fn s ->
     last = List.last(s.entries)
     %{s | entries: Enum.drop(s.entries, -1) ++ [%{last | parent_id: hd(s.entries).id}]}
   end},
  {"wrong B result ID",
   fn s ->
     rewrite.(s, fn
       %ToolResult{call_id: "call-B"} = m -> %{m | call_id: "wrong"}
       m -> m
     end)
   end},
  {"active input C", fn s -> %{s | active_input_id: "accepted-C"} end},
  {"leading terminal assistant",
   fn s ->
     [first | rest] = s.entries
     pre = %{first | id: "preamble", message: %Assistant{text: "unrelated answer"}}
     %{s | entries: [pre, %{first | parent_id: pre.id} | rest]}
   end},
  {"leading orphan tool result",
   fn s ->
     [first | rest] = s.entries

     pre = %{
       first
       | id: "preamble",
         message: %ToolResult{call_id: "orphan", name: "lab_marker", outcome: {:ok, "unexpected"}}
     }

     %{s | entries: [pre, %{first | parent_id: pre.id} | rest]}
   end}
]

show.("valid control", base)

for {label, mutate} <- mutations do
  {:ok, saved} = Store.save(mutate.(base))

  case Store.open(saved.path, root) do
    {:ok, loaded} -> show.(label, loaded)
    {:error, reason} -> IO.inspect({label, reason}, label: "decoder rejected")
  end
end

base = reopen.(base)

for {recovery, backlog} <- [{5000, 7000}, {5001, 5002}, {5000, 7001}] do
  w =
    witness.(base)
    |> Map.put(:recovery_ms, recovery)
    |> Map.put(:backlog_ms, backlog)
    |> put_in([:clocks, :recovery, :ms], recovery)
    |> put_in([:clocks, :recovery, :endpoint_at], 5 + recovery)
    |> put_in([:clocks, :backlog, :ms], backlog)
    |> put_in([:clocks, :backlog, :endpoint_at], 5 + backlog)

  r = Observer.report(w, cleanup)
  IO.inspect({recovery, backlog, r.complete, r.bounds, r.incomplete}, label: "threshold")
end

shifted =
  witness.(base)
  |> put_in([:clocks, :recovery, :origin_at], -100)
  |> put_in([:clocks, :recovery, :endpoint_at], -90)

r = Observer.report(shifted, cleanup)

IO.inspect({r.complete, r.bounds, Elara.Lab.failed_checks(r)},
  label: "recovery clock before target death"
)

{:ok, coordinator} = Coordinator.start_link(fault: :provider_started)
owner = self()
started = Jobs.now()
result = Deadline.call(coordinator, :start, started - 1, fn -> send(owner, :expired_ran) end)

side_effect =
  receive do
    :expired_ran -> true
  after
    30 -> false
  end

IO.inspect({result, side_effect}, label: "expired start and side effect")

IO.inspect(StoreView.await_failed(base.path, root, "accepted-A", coordinator, Jobs.now() - 1),
  label: "expired store"
)

:sys.suspend(coordinator)

spawn(fn ->
  Process.sleep(100)
  :sys.resume(coordinator)
end)

started = Jobs.now()
result = Deadline.call(coordinator, :probe, started + 20, fn -> send(owner, :delayed_ran) end)
elapsed = Jobs.now() - started

side_effect =
  receive do
    :delayed_ran -> true
  after
    120 -> false
  end

IO.inspect({result, elapsed, side_effect}, label: "delayed coordinator result ms side effect")
fifo = Path.join(root, "fifo")
{_, 0} = System.cmd("mkfifo", [fifo])

writer =
  Port.open({:spawn_executable, "/bin/sh"}, [
    :exit_status,
    args: ["-c", "sleep 0.15; cat \"$1\" > \"$2\"", "writer", base.path, fifo]
  ])

started = Jobs.now()
result = StoreView.await_failed(fifo, root, "accepted-A", coordinator, started + 20)
IO.inspect({result, Jobs.now() - started}, label: "blocked store result ms")

receive do
  {^writer, {:exit_status, status}} -> IO.inspect(status, label: "writer exit")
after
  1000 -> Port.close(writer)
end

{:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

opts = [
  cwd: root,
  home: root,
  skill_paths: [],
  plugins: [],
  tools: [],
  persist: true,
  provider: Elara.Provider.Simulated.new(seed: 42, id: "late-independent")
]

deadline = Jobs.now() + 100

caller =
  Task.async(fn ->
    Deadline.call(coordinator, :start, deadline, fn ->
      send(owner, {:helper, self()})

      receive do
        :finish -> Elara.start_session_under(supervisor, opts)
      end
    end)
  end)

helper =
  receive do
    {:helper, pid} -> pid
  after
    500 -> raise "helper missing"
  end

IO.inspect(helper in Coordinator.snapshot(coordinator).helpers,
  label: "ownership before side effect"
)

true = :erlang.suspend_process(caller.pid)
Process.sleep(max(deadline - Jobs.now() + 20, 0))
send(helper, :finish)
Process.sleep(50)
true = :erlang.resume_process(caller.pid)
result = Task.await(caller, 1000)
state = Coordinator.snapshot(coordinator)

IO.inspect(
  {result, state.unresolved, state.sessions, state.helpers,
   DynamicSupervisor.count_children(supervisor).active},
  label: "late successful start result unresolved sessions helpers live children"
)

DynamicSupervisor.stop(supervisor)

# The ordinary timed-out start must still preserve unresolved ownership.
{:ok, supervisor2} = DynamicSupervisor.start_link(strategy: :one_for_one)
:sys.suspend(supervisor2)

result =
  Deadline.call(coordinator, :reopen, Jobs.now() + 20, fn ->
    Elara.start_session_under(supervisor2, opts)
  end)

state = Coordinator.snapshot(coordinator)
:sys.resume(supervisor2)
Process.sleep(50)

IO.inspect({result, state.unresolved, DynamicSupervisor.count_children(supervisor2).active},
  label: "blocked reopen result unresolved live children"
)

DynamicSupervisor.stop(supervisor2)
Coordinator.stop(coordinator)
File.rm_rf!(root)
