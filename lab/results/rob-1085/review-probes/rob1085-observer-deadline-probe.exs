alias Elara.Lab.Scenarios.SessionRecovery.{Coordinator, Deadline, Observer, StoreView}
alias Elara.Session.Store
alias Elara.Message.{User, Assistant, ToolCall, ToolResult}
alias Elara.Lab.Jobs

root = Path.join(System.tmp_dir!(), "rob1085-probe-#{System.unique_integer([:positive])}")
File.mkdir_p!(root)
Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))
accepted = Map.new(~w(A B C), &{&1, %{id: "accepted-#{&1}", text: "input #{&1}"}})
store = Store.new(root)

store =
  Enum.reduce(~w(A B C), store, fn label, store ->
    {:ok, store} = Store.append(store, %User{text: "input #{label}"})

    if label == "A" do
      store
    else
      call = %ToolCall{id: "call-#{label}", name: "lab_marker", args: {:ok, %{"label" => label}}}
      {:ok, store} = Store.append(store, %Assistant{tool_calls: [call]})

      {:ok, store} =
        Store.append(store, %ToolResult{
          call_id: call.id,
          name: call.name,
          outcome: {:ok, "marked #{label}"}
        })

      {:ok, store} = Store.append(store, %Assistant{text: "done #{label}"})
      store
    end
  end)

inbox =
  Enum.map(~w(A B C), fn label ->
    %{
      id: accepted[label].id,
      session_id: store.id,
      sender_id: "lab",
      kind: :normal,
      state: if(label == "A", do: :failed, else: :consumed),
      error: if(label == "A", do: "provider died", else: nil),
      user: %User{text: accepted[label].text},
      created_at: 1
    }
  end)

{:ok, store} = Store.put_inbox(store, inbox, false)
File.write!(Path.join(root, "marks.txt"), "B\nC\n")
{:ok, persisted} = Store.open(store.path, root)

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
  death: %{matched: true, target: "pid", reason: :killed, at: 5},
  ordering: %{
    monitor_installed_at: 1,
    arrived_at: 1,
    backlog_observed_at: 2,
    released_at: 3,
    injected_at: 4,
    target_down_at: 5,
    backlog_ids: ["accepted-B", "accepted-C"]
  }
}

cleanup = %{confirmed: true, choices: %{}}
witness = StoreView.witness(persisted, attrs) |> Map.merge(protocol)

show = fn name, w ->
  r = Observer.report(w, cleanup)
  IO.inspect({name, r.complete, r.bounds, Elara.Lab.failed_checks(r)}, limit: :infinity)
end

show.("baseline independent persisted store", witness)

IO.inspect(witness.inputs |> Map.new(fn {k, v} -> {k, {v.accepted_id, v.persisted_user_id}} end),
  label: "actual distinct IDs"
)

show.("unrelated barrier ids", put_in(witness.ordering.backlog_ids, ["wrong-X", "wrong-Y"]))

show.(
  "missing injection/death times",
  witness
  |> put_in([:ordering, :injected_at], nil)
  |> put_in([:ordering, :target_down_at], nil)
  |> put_in([:death, :at], nil)
)

show.(
  "999999ms clocks but 10/20ms summaries",
  witness
  |> put_in([:clocks, :recovery, :endpoint_at], 1_000_004)
  |> put_in([:clocks, :recovery, :ms], 999_999)
)

show.(
  "honest bound violation",
  witness
  |> Map.put(:recovery_ms, 5001)
  |> put_in([:clocks, :recovery, :endpoint_at], 5006)
  |> put_in([:clocks, :recovery, :ms], 5001)
)

for {name, change} <- [
      {"reused B/C call IDs",
       fn s ->
         %{
           s
           | entries:
               Enum.map(s.entries, fn e ->
                 m =
                   case e.message do
                     %Assistant{tool_calls: [call]} = a ->
                       %{a | tool_calls: [%{call | id: "shared"}]}

                     %ToolResult{} = r ->
                       %{r | call_id: "shared"}

                     other ->
                       other
                   end

                 %{e | message: m}
               end)
         }
       end},
      {"extra interrupted answer before C terminal",
       fn s ->
         last = List.last(s.entries)
         extra = %{last | id: "extra", message: %Assistant{text: "stale", interrupted: true}}
         %{s | entries: List.insert_at(s.entries, length(s.entries) - 1, extra)}
       end},
      {"wrong receipt user B",
       fn s ->
         %{
           s
           | inbox:
               Enum.map(s.inbox, fn i ->
                 if i.id == "accepted-B", do: %{i | user: %User{text: "WRONG INPUT"}}, else: i
               end)
         }
       end},
      {"leaf before completed C", fn s -> %{s | leaf: Enum.at(s.entries, 4).id} end}
    ] do
  {:ok, changed} = Store.save(change.(persisted))
  {:ok, decoded} = Store.open(changed.path, root)
  show.(name, StoreView.witness(decoded, attrs) |> Map.merge(protocol))
end

{:ok, _} = Store.save(persisted)
raw = File.read!(store.path)
[header | rest] = String.split(raw, "\n")
header = JSON.decode!(header) |> update_in(["inbox"], &Map.delete(&1, "activeId"))
File.write!(store.path, Enum.join([JSON.encode!(header) | rest], "\n"))
{:ok, missing_active} = Store.open(store.path, root)
show.("missing raw activeId", StoreView.witness(missing_active, attrs) |> Map.merge(protocol))

IO.inspect(StoreView.await_failed(store.path, root, "accepted-A", Jobs.now() - 1000) |> elem(0),
  label: "expired StoreView succeeds"
)

fifo = Path.join(root, "blocked-store")
System.cmd("mkfifo", [fifo])

writer =
  Port.open({:spawn_executable, "/bin/sh"}, [
    :exit_status,
    args: ["-c", "sleep 0.15; cat \"$1\" > \"$2\"", "writer", store.path, fifo]
  ])

started = Jobs.now()
result = StoreView.await_failed(fifo, root, "accepted-A", started + 20)

IO.inspect({elem(result, 0), Jobs.now() - started},
  label: "20ms store deadline with blocked read"
)

receive do
  {^writer, {:exit_status, 0}} -> :ok
after
  1000 -> raise "writer timeout"
end

{:ok, c} = Coordinator.start_link(fault: :provider_started)
:sys.suspend(c)

Task.start(fn ->
  Process.sleep(100)
  :sys.resume(c)
end)

started = Jobs.now()
result = Deadline.call(c, :probe, started + 20, fn -> :completed end)
IO.inspect({result, Jobs.now() - started}, label: "20ms deadline with delayed coordinator")
:sys.suspend(c)

Task.start(fn ->
  Process.sleep(30)
  :sys.resume(c)
end)

owner = self()

result =
  Deadline.call(c, :start, Jobs.now() - 1, fn ->
    send(owner, :expired_operation_executed)
    :started
  end)

IO.inspect(result, label: "expired start")

receive do
  :expired_operation_executed -> IO.puts("expired start side effect executed")
after
  0 -> :ok
end

Coordinator.stop(c)

IO.inspect(JSON.decode!(JSON.encode!(Observer.report(witness, cleanup)))["complete"],
  label: "full report JSON serialization"
)

File.rm_rf!(root)
