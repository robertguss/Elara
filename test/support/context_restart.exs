# Separate BEAMs exercise safe atom decoding and abrupt VM loss, not just actor restart.
[root, mode, stage] = System.argv()
Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))
{:ok, _} = Application.ensure_all_started(:elara)

defmodule ContextRestartProvider do
  @behaviour Elara.Provider
  def chat({root, mode} = config, _request) do
    File.write!(Path.join(root, "requests"), "request\n", [:append, :sync])
    if mode == "prepare", do: Process.sleep(:infinity)
    {:ok, %Elara.Message.Assistant{text: "continued after VM restart"}, config}
  end
end

defmodule ContextRestartWait do
  def until(fun, n \\ 500)
  def until(_, 0), do: raise("restart condition did not converge")

  def until(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          until(fun, n - 1)
        )
  end
end

provider = {ContextRestartProvider, {root, mode}}

if mode == "prepare" do
  hook = fn reached ->
    if reached == stage do
      if stage in ["activated", "started"],
        do: ContextRestartWait.until(fn -> File.exists?(Path.join(root, "requests")) end)

      System.halt(0)
    end
  end

  {:ok, id} =
    Elara.start_session(
      cwd: root,
      provider: provider,
      tools: [],
      plugins: [],
      pause_inputs: true,
      context_limit: 100_000,
      max_tool_output_bytes: 1024,
      handoff_fault_hook: hook,
      seed_history: [%Elara.Message.Assistant{text: String.duplicate("archive", 9000)}]
    )

  File.write!(Path.join(root, "source"), id)

  {:ok, _} =
    Elara.submit_input(id, %{
      id: "original-input",
      sender_id: "owner",
      kind: :steer,
      user: Elara.Message.user("retain this obligation")
    })

  {:ok, _} =
    Elara.submit_input(id, %{
      id: "queued-input",
      sender_id: "owner",
      kind: :normal,
      user: Elara.Message.user("queued owner follow-up")
    })

  Process.sleep(:infinity)
else
  source = File.read!(Path.join(root, "source"))
  {:ok, old} = Elara.Session.Handoff.store(source)
  successor = old.context["handoff"]["id"]
  {:ok, ^source} = Elara.start_session(cwd: root, provider: provider, resume: old.path)

  ContextRestartWait.until(fn ->
    {:ok, s} = Elara.Session.Handoff.store(source)

    get_in(s.context, ["handoff", "stage"]) == "started" and
      match?({:ok, _}, Elara.session_pid(successor))
  end)

  ContextRestartWait.until(fn ->
    {:ok, s} = Elara.Session.Handoff.store(successor)
    Enum.any?(s.inbox, &(&1.id == "handoff:" <> successor and &1.state in [:consumed, :failed]))
  end)

  Process.sleep(100)
  {:ok, s} = Elara.Session.Handoff.store(successor)
  uncertain? = stage in ["activated", "started"]
  count = if uncertain?, do: 1, else: 2
  true = Enum.count(s.entries, &match?(%{message: %Elara.Message.User{}}, &1)) == count
  true = File.read!(Path.join(root, "requests")) == String.duplicate("request\n", count)
  [queued] = Enum.filter(s.inbox, &(&1.id == "queued-input"))
  true = queued.user.text == "queued owner follow-up"

  expected =
    if uncertain?, do: Enum.find(old.inbox, &(&1.id == "queued-input")).state, else: :consumed

  if queued.state != expected,
    do: raise("queued state #{inspect(queued.state)}, expected #{inspect(expected)}")

  true = length(Elara.Session.Store.list(root)) == 2
  if stage in ["activated", "started"], do: true = s.inputs_paused
  IO.puts("fresh BEAM #{stage}: one identity, one consumption, no request replay")
end
