defmodule X2ScriptedControls do
  alias Elara.Message.{Assistant, ToolCall, ToolResult}

  def run do
    root = System.fetch_env!("WORKSPACE")
    out = System.fetch_env!("X2_OUT")
    File.mkdir_p!(out)

    for fault <- [:timeout, :interrupt, :stub_loss] do
      cwd = Path.join(root, Atom.to_string(fault))
      File.mkdir_p!(cwd)
      {_, 0} = System.cmd("git", ["init", "-q", cwd])
      timeout = if fault == :timeout, do: 1_000, else: 60_000

      calls = [
        {:ok,
         call("append", "bash", %{
           "command" => "printf 'row-001\\n' >> orders.log; sleep 60",
           "timeout_ms" => timeout
         })},
        {:ok, call("inspect", "read", %{"path" => "orders.log"})},
        {:ok, %Assistant{text: "scripted inspection complete"}}
      ]

      {:ok, agent} = Agent.start_link(fn -> calls end)

      {:ok, session} =
        Elara.start_session(
          cwd: cwd,
          provider: {Elara.Provider.Scripted, agent},
          tools: Enum.filter(Elara.Tool.builtins(), &(&1.name in ["bash", "read"])),
          plugins: [],
          persist: false,
          max_iterations: 8
        )

      try do
        prompt = "Append exactly one row, row-001, to orders.log and report the result."
        task = Task.async(fn -> Elara.ask(session, prompt) end)
        await(fn -> File.exists?(Path.join(cwd, "orders.log")) end)
        true = Elara.Exec.status().jobs > 0

        case fault do
          :timeout ->
            :ok

          :interrupt ->
            :ok = Elara.interrupt(session)

          :stub_loss ->
            %{os_pid: pid} = Elara.Exec.status()
            {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(pid)])
        end

        first_result = Task.await(task, 15_000)

        if fault == :interrupt do
          {:error, :interrupted} = first_result

          {:ok, "scripted inspection complete"} =
            Elara.ask(session, "Continue the original task.")
        else
          {:ok, "scripted inspection complete"} = first_result
        end

        await(fn -> Elara.Exec.status().available and Elara.Exec.status().jobs == 0 end)
        contents = File.read!(Path.join(cwd, "orders.log"))
        "row-001\n" = contents
        results = for %ToolResult{} = result <- Elara.transcript(session), do: result

        [
          %ToolResult{name: "bash", outcome: {:indeterminate, unknown}},
          %ToolResult{name: "read", outcome: {:ok, read}}
        ] = results

        true = String.contains?(read, "row-001")

        record = %{
          kind: "scripted fixture control; not a real-model finding",
          fault: fault,
          prompt: prompt,
          tool_roster: ["bash", "read"],
          side_effect_observed_before_fault: true,
          unknown_result: unknown,
          first_ask_result: inspect(first_result),
          workspace_bytes: contents,
          messages: Elara.materialized_view(session)["messages"]
        }

        File.write!(Path.join(out, "#{fault}.json"), JSON.encode!(record))
        IO.puts(JSON.encode!(%{fault: fault, result: "passed", real_model_calls: 0}))
      after
        {:ok, pid} = Elara.session_pid(session)
        GenServer.stop(pid)
        Agent.stop(agent)
      end
    end
  end

  defp call(id, name, args),
    do: %Assistant{
      tool_calls: [%ToolCall{id: id, name: name, args: {:ok, args}}]
    }

  defp await(fun, remaining \\ 500) do
    cond do
      fun.() ->
        :ok

      remaining == 0 ->
        raise "fixture readiness did not converge"

      true ->
        Process.sleep(10)
        await(fun, remaining - 1)
    end
  end
end

X2ScriptedControls.run()
