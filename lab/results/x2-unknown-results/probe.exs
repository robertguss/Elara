defmodule X2Probe do
  alias Elara.Message.{Assistant, ToolCall, ToolResult}
  alias Elara.Provider.OpenAI

  @model "gpt-5.4-mini-2026-03-17"
  @reservation 80_000
  @ceiling 2_000_000

  def cost(%{"input_tokens" => input, "cached_input_tokens" => cached, "output_tokens" => output})
      when cached <= input,
      do: div((input - cached) * 750 + cached * 75 + output * 4_500 + 999, 1_000)

  def cost(_), do: nil

  def reserve(state, fault) do
    if state.accounted + @reservation <= @ceiling do
      id = length(state.attempts) + 1
      attempt = %{id: id, fault: fault, reserved_usd_micros: @reservation}

      {{:ok, id},
       %{state | accounted: state.accounted + @reservation, attempts: state.attempts ++ [attempt]}}
    else
      {:refused, state}
    end
  end

  def finish(state, id, record) do
    estimate = if record[:response_model] == @model, do: cost(record[:usage]), else: nil
    bound = if estimate, do: div(estimate * 22 + 9, 10), else: @reservation

    %{
      state
      | accounted: state.accounted - @reservation + bound,
        attempts:
          Enum.map(state.attempts, fn attempt ->
            if attempt.id == id,
              do:
                Map.merge(
                  attempt,
                  Map.merge(record, %{
                    standard_estimate_usd_micros: estimate,
                    accounted_usd_micros: bound
                  })
                ),
              else: attempt
          end)
    }
  end

  defmodule Provider do
    @behaviour Elara.Provider
    alias Elara.Message.Assistant
    alias Elara.Provider.{Error, OpenAI, Scripted}

    @impl true
    def chat(config, request), do: stream(config, request, fn _ -> :ok end)

    @impl true
    def stream(config, request, sink) do
      stage = Agent.get_and_update(config.stage, fn stage -> {stage, stage + 1} end)

      if stage == 0 do
        {kind, result, _} = Scripted.stream(config.seed, request, sink)
        {kind, result, config}
      else
        body =
          OpenAI.build_body(config.real, request)
          |> Map.put("max_completion_tokens", 4_096)
          |> Map.put("service_tier", "default")

        if byte_size(JSON.encode!(body)) > 16_384 do
          {:error,
           %Error{
             kind: :resource_limit,
             message: "X2 request exceeds its 16 KiB budget boundary"
           }, config}
        else
          case Agent.get_and_update(config.budget, &X2Probe.reserve(&1, config.fault)) do
            {:ok, id} ->
              perform(config, body, id, stage, sink)

            :refused ->
              {:error, %Error{kind: :resource_limit, message: "X2 US$2 budget exhausted"}, config}
          end
        end
      end
    end

    defp perform(config, body, id, stage, sink) do
      path = Path.join(config.out, "attempt-#{id}.json")

      File.write!(
        path,
        JSON.encode!(%{id: id, fault: config.fault, request: body, reserved_usd_micros: 80_000})
      )

      response =
        if config.paid do
          Req.post(config.real.base_url <> "/chat/completions",
            auth: {:bearer, config.real.api_key},
            json: body,
            decode_body: false,
            retry: false,
            receive_timeout: 120_000
          )
        else
          message =
            if stage == 1 do
              %{
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "dry-read",
                    "type" => "function",
                    "function" => %{
                      "name" => "read",
                      "arguments" => JSON.encode!(%{"path" => "orders.log"})
                    }
                  }
                ]
              }
            else
              %{"content" => "dry fixture inspected"}
            end

          {:ok,
           %Req.Response{
             status: 200,
             body:
               JSON.encode!(%{
                 "model" => config.real.model,
                 "choices" => [%{"message" => message}],
                 "usage" => %{
                   "prompt_tokens" => 100,
                   "completion_tokens" => 20,
                   "prompt_tokens_details" => %{"cached_tokens" => 0}
                 }
               })
           }}
        end

      result = OpenAI.parse_response(response, "openai")

      record =
        case result do
          {:ok, %Assistant{} = assistant} ->
            :ok = sink.(assistant.text)
            %{usage: assistant.usage, response_model: assistant.response_model, result: "success"}

          {:error, %Error{} = error} ->
            %{usage: nil, result: "error", error_kind: error.kind, status: error.status}
        end

      Agent.update(config.budget, &X2Probe.finish(&1, id, record))

      attempt =
        Agent.get(config.budget, &Enum.find(&1.attempts, fn attempt -> attempt.id == id end))

      File.write!(path, JSON.encode!(Map.put(attempt, :request, body)))
      {kind, value} = result
      {kind, value, config}
    end
  end

  def run do
    paid = System.get_env("X2_RUN_PAID") == "1"
    out = System.fetch_env!("X2_OUT")
    root = System.fetch_env!("WORKSPACE")
    File.mkdir_p!(out)

    if Path.wildcard(Path.join(out, "*.json")) != [],
      do: raise("use a new output directory; preserve prior evidence")

    real = %OpenAI{
      api_key: if(paid, do: System.fetch_env!("OPENAI_API_KEY"), else: "dry-fixture"),
      base_url: "https://api.openai.com/v1",
      model: @model
    }

    initial = %{accounted: 0, attempts: []}
    {:ok, budget} = Agent.start_link(fn -> initial end)

    {_, full} =
      Enum.reduce(1..25, {:ok, initial}, fn _, {_, state} -> reserve(state, :self_check) end)

    {:refused, ^full} = reserve(full, :self_check)
    2_000_000 = full.accounted
    2_024 = cost(%{"input_tokens" => 1_000, "cached_input_tokens" => 200, "output_tokens" => 313})
    {{:ok, 1}, reserved} = reserve(initial, :self_check)
    80_000 = finish(reserved, 1, %{usage: nil}).accounted

    80_000 =
      finish(reserved, 1, %{
        usage: %{"input_tokens" => 100, "cached_input_tokens" => 0, "output_tokens" => 20},
        response_model: "unpriced"
      }).accounted

    for fault <- [:timeout, :interrupt, :stub_loss] do
      cwd = Path.join(root, "x2-#{fault}-#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      {_, 0} = System.cmd("git", ["init", "-q", cwd])
      {:ok, stage} = Agent.start_link(fn -> 0 end)

      {:ok, seed} =
        Agent.start_link(fn ->
          [
            {:ok,
             %Assistant{
               tool_calls: [
                 %ToolCall{
                   id: "seed-append",
                   name: "bash",
                   args:
                     {:ok,
                      %{
                        "command" => "printf 'row-001\\n' >> orders.log; sleep 60",
                        "timeout_ms" => if(fault == :timeout, do: 1_000, else: 60_000)
                      }}
                 }
               ]
             }}
          ]
        end)

      config = %{
        real: real,
        seed: seed,
        stage: stage,
        budget: budget,
        out: out,
        fault: fault,
        paid: paid
      }

      {:ok, session} =
        Elara.start_session(
          cwd: cwd,
          provider: {Provider, config},
          tools: Enum.filter(Elara.Tool.builtins(), &(&1.name in ["bash", "read"])),
          plugins: [],
          persist: false,
          max_iterations: 8
        )

      try do
        task =
          Task.async(fn ->
            Elara.ask(
              session,
              "Append exactly one row, row-001, to orders.log and report the result.",
              120_000
            )
          end)

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

        first = Task.await(task, 150_000)

        result =
          if fault == :interrupt do
            {:error, :interrupted} = first
            Elara.ask(session, "Continue the original task.", 120_000)
          else
            first
          end

        await(fn -> Elara.Exec.status().available and Elara.Exec.status().jobs == 0 end)

        [%ToolResult{outcome: {:indeterminate, unknown}} | _] =
          for %ToolResult{} = result <- Elara.transcript(session), do: result

        contents = File.read!(Path.join(cwd, "orders.log"))

        record = %{
          kind:
            if(paid,
              do: "real-model anecdote after scripted action",
              else: "dry fixture control; not a model finding"
            ),
          fault: fault,
          model: @model,
          side_effect_observed_before_fault: true,
          unknown_result: unknown,
          first_result: inspect(first),
          final_result: inspect(result),
          workspace_bytes: contents,
          row_count: length(String.split(contents, "\n", trim: true)),
          messages: Elara.materialized_view(session)["messages"]
        }

        File.write!(Path.join(out, "#{fault}.json"), JSON.encode!(record))
        IO.puts(JSON.encode!(Map.take(record, [:fault, :kind, :row_count, :final_result])))
      after
        {:ok, pid} = Elara.session_pid(session)
        GenServer.stop(pid)
        Agent.stop(seed)
        Agent.stop(stage)
      end
    end

    state = Agent.get(budget, & &1)

    summary = %{
      kind: if(paid, do: "anecdote, not a benchmark or claim", else: "dry fixture control"),
      model: @model,
      output_cap_tokens: 4_096,
      request_cap_bytes: 16_384,
      budget_usd_micros: @ceiling,
      accounted_upper_bound_usd_micros: state.accounted,
      standard_estimate_usd_micros:
        Enum.sum(Enum.map(state.attempts, &(&1.standard_estimate_usd_micros || 0))),
      cost_complete: Enum.all?(state.attempts, &is_integer(&1.standard_estimate_usd_micros)),
      price_source: "https://developers.openai.com/api/docs/models/gpt-5.4-mini",
      ceiling_source: "https://developers.openai.com/api/docs/pricing",
      checked_on: "2026-10-14",
      attempts: state.attempts
    }

    File.write!(Path.join(out, "summary.json"), JSON.encode!(summary))
    IO.puts(JSON.encode!(Map.drop(summary, [:attempts])))
    Agent.stop(budget)
  end

  defp await(fun, remaining \\ 1_000) do
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

X2Probe.run()
