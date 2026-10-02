alias Elara.Lab.Scenarios.SessionRecovery.{Coordinator, Deadline}
alias Elara.Lab.Jobs
root = Path.join(System.tmp_dir!(), "rob1085-start-probe")
File.mkdir_p!(root)
Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))
{:ok, c} = Coordinator.start_link(fault: :provider_started)
{:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
:sys.suspend(sup)
owner = self()

spawn(fn ->
  result =
    Deadline.call(c, :start, Jobs.now() + 200, fn ->
      Elara.start_session_under(sup,
        cwd: root,
        home: root,
        skill_paths: [],
        plugins: [],
        tools: [],
        persist: true,
        provider: Elara.Provider.Simulated.new(seed: 42, id: "start-probe")
      )
    end)

  send(owner, {:start_result, result})
end)

receive do
  {:start_result, r} -> IO.inspect(r, label: "real supervised start timeout")
after
  2000 -> raise "outer timeout"
end

IO.inspect(Coordinator.snapshot(c) |> Map.take([:unresolved, :helpers, :sessions]),
  label: "ownership after timeout"
)

:sys.resume(sup)
Process.sleep(100)
children = DynamicSupervisor.which_children(sup)
IO.inspect(length(children), label: "late supervised children")
Enum.each(children, fn {_, pid, _, _} -> DynamicSupervisor.terminate_child(sup, pid) end)
Supervisor.stop(sup)
Coordinator.stop(c)
File.rm_rf!(root)
