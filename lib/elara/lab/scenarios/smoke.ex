defmodule Elara.Lab.Scenarios.Smoke do
  @moduledoc """
  Reference lab scenario: `sessions` concurrent persistent sessions, each asking
  `turns` user turns through the simulated provider. Each turn runs a `read` and a
  short `bash`, then streams an answer. Measures delta latency from intended
  emission to arrival at a session subscriber, and digests every choice.

  Params (strings): `sessions` (default 4), `turns` (3), `answer_deltas` (20),
  `ttft_ms` (50), `deltas_per_sec` (200), `bash_ms` (20), `rate_limited_pct` (3),
  `server_error_pct` (2).
  """

  @behaviour Elara.Lab

  alias Elara.Provider.Retry
  alias Elara.Provider.Simulated

  @impl true
  def run(%{provider: :real} = context), do: run_real(context)

  def run(%{seed: seed, dir: dir, params: params}) do
    sessions = int(params, "sessions", 4)
    turns = int(params, "turns", 3)
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "fixture.txt"), String.duplicate("lab fixture\n", 340))

    profile = [
      ttft_ms: int(params, "ttft_ms", 50),
      deltas_per_sec: int(params, "deltas_per_sec", 200),
      delta_bytes: 20,
      answer_deltas: int(params, "answer_deltas", 20),
      tool_rounds: 2,
      # Per-request error rates, in percent; the default makes choices seed-dependent.
      errors: [
        rate_limited: int(params, "rate_limited_pct", 3) / 100,
        server_error: int(params, "server_error_pct", 2) / 100
      ],
      tool_plan: [
        {"read", %{"path" => "fixture.txt"}},
        {"bash", %{"command" => "sleep #{int(params, "bash_ms", 20) / 1000}"}}
      ]
    ]

    tools = Enum.filter(Elara.Tool.builtins(), &(&1.name in ["read", "bash"]))

    started =
      for index <- 1..sessions do
        sim_id = "s#{index}"
        provider = Simulated.new(seed: seed, id: sim_id, profile: profile, collector: self())

        {:ok, id} =
          Elara.start_session(
            provider: provider,
            cwd: workspace,
            plugins: [],
            tools: tools,
            provider_retry: Retry.disabled(),
            context_limit: 1_000_000
          )

        :ok = Elara.subscribe(id)
        {id, sim_id}
      end

    by_session = Map.new(started)

    tasks =
      for {id, _sim} <- started do
        Task.async(fn -> for turn <- 1..turns, do: Elara.ask(id, "turn #{turn}") end)
      end

    state =
      collect(%{
        by_session: by_session,
        tasks: MapSet.new(tasks, & &1.ref),
        ended: Map.new(started, fn {id, _} -> {id, 0} end),
        expected_turns: turns,
        intended: %{},
        latency: [],
        choices: %{},
        outcomes: []
      })

    Enum.each(started, fn {id, _} -> stop(id) end)

    choices = Map.new(state.choices, fn {sim, list} -> {sim, Enum.reverse(list)} end)

    %{
      sessions: sessions,
      turns: turns,
      completed_turns: Enum.count(state.outcomes, &match?({:ok, _}, &1)),
      failed_turns: Enum.count(state.outcomes, &(not match?({:ok, _}, &1))),
      choices_digest: Elara.Lab.digest(choices),
      latency_ms: state.latency
    }
  end

  # Real mode: the configured provider, unwrapped (a wrapper would hide its module
  # and lose model settings). The request cap is static: each turn makes at most
  # max_iterations provider requests, so sessions * turns * max_iterations <= cap.
  defp run_real(%{dir: dir, params: params, max_requests: cap}) do
    sessions = int(params, "sessions", 1)
    turns = int(params, "turns", 1)

    max_iterations =
      if is_integer(cap),
        do: div(cap, sessions * turns),
        else: raise("real mode requires --max-requests")

    if max_iterations < 1,
      do: raise("--max-requests #{cap} is below one request per turn (#{sessions * turns} turns)")

    {:ok, provider} = Elara.Config.resolve()
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "fixture.txt"), "elara lab fixture\n")
    tools = Enum.filter(Elara.Tool.builtins(), &(&1.name in ["read", "bash"]))
    prompt = "Use the read tool on fixture.txt, then reply with only its first word."

    tasks =
      for _ <- 1..sessions do
        {:ok, id} =
          Elara.start_session(
            provider: provider,
            cwd: workspace,
            plugins: [],
            tools: tools,
            provider_retry: Retry.disabled(),
            max_iterations: min(max_iterations, 12)
          )

        Task.async(fn ->
          started = System.monotonic_time(:millisecond)
          outcomes = for _ <- 1..turns, do: Elara.ask(id, prompt)
          stop(id)
          {outcomes, System.monotonic_time(:millisecond) - started}
        end)
      end

    results = Task.await_many(tasks, :timer.minutes(5))
    outcomes = Enum.flat_map(results, &elem(&1, 0))

    %{
      sessions: sessions,
      turns: turns,
      provider: :real,
      request_cap: cap,
      max_iterations: min(max_iterations, 12),
      completed_turns: Enum.count(outcomes, &match?({:ok, _}, &1)),
      failed_turns: Enum.count(outcomes, &(not match?({:ok, _}, &1))),
      answers: for({:ok, text} <- outcomes, do: String.slice(text, 0, 80)),
      session_ms: Enum.map(results, &elem(&1, 1))
    }
  end

  defp collect(state) do
    if MapSet.size(state.tasks) == 0 and
         Enum.all?(state.ended, fn {_, n} -> n >= state.expected_turns end) do
      state
    else
      receive do
        {:lab_choice, sim, _request, choice} ->
          collect(
            update_in(
              state.choices,
              &Map.update(&1, sim, [choice], fn list -> [choice | list] end)
            )
          )

        {:lab_delta, sim, _request, _index, intended} ->
          collect(
            update_in(
              state.intended,
              &Map.update(&1, sim, [intended], fn list -> list ++ [intended] end)
            )
          )

        {:elara, id, {:content_delta, _stream, _text}} ->
          now = System.monotonic_time(:millisecond)
          sim = Map.fetch!(state.by_session, id)
          [intended | rest] = Map.fetch!(state.intended, sim)
          state = put_in(state.intended[sim], rest)
          collect(%{state | latency: [now - intended | state.latency]})

        {:elara, id, event} when elem(event, 0) == :turn_ended ->
          collect(update_in(state.ended[id], &(&1 + 1)))

        {ref, outcomes} when is_reference(ref) ->
          if MapSet.member?(state.tasks, ref) do
            Process.demonitor(ref, [:flush])

            collect(%{
              state
              | tasks: MapSet.delete(state.tasks, ref),
                outcomes: state.outcomes ++ outcomes
            })
          else
            collect(state)
          end

        _other ->
          collect(state)
      after
        60_000 -> raise "smoke scenario made no progress for 60 seconds"
      end
    end
  end

  defp stop(id) do
    case Elara.session_pid(id) do
      {:ok, pid} -> GenServer.stop(pid)
      _ -> :ok
    end
  end

  defp int(params, key, default) do
    case Map.fetch(params, key) do
      {:ok, value} -> String.to_integer(value)
      :error -> default
    end
  end
end
