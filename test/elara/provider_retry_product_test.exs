defmodule Elara.ProviderRetryProductTest do
  @moduledoc """
  ROB-1343 through the public session path: a flaky provider survives a turn,
  a terminal one does not, and neither duplicates the session record. Scripted
  and simulated providers only; no network and no credentials.
  """
  use ExUnit.Case, async: false

  alias Elara.Message
  alias Elara.Message.ToolCall
  alias Elara.Provider
  alias Elara.Provider.Retry
  alias Elara.Provider.Simulated
  alias Elara.Session.Store

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp asst(text, calls \\ []) do
    {:ok, assistant} = Message.assistant(text, calls)
    assistant
  end

  defp overloaded, do: %Provider.Error{kind: :http, status: 503, message: "503 overloaded"}

  defp unauthorized, do: %Provider.Error{kind: :http, status: 401, message: "401 unauthorized"}

  defp unique_cwd do
    Path.join(
      Application.fetch_env!(:elara, :sessions_root),
      "cwd-#{System.unique_integer([:positive])}"
    )
  end

  defp start(provider, opts) do
    defaults = [
      provider: provider,
      tools: [],
      plugins: [],
      persist: false,
      provider_retry: [max_attempts: 3, base_delay_ms: 10, max_delay_ms: 20]
    ]

    {:ok, session} = Elara.start_session(Keyword.merge(defaults, opts))
    session
  end

  defp tool do
    %Elara.Tool{
      name: "echo",
      description: "echo",
      parameters: %{"type" => "object", "properties" => %{}},
      run: {__MODULE__, :echo}
    }
  end

  def echo(_args, _ctx), do: {:ok, "echoed"}

  test "a transient failure is retried and the turn completes with one assistant message" do
    cwd = unique_cwd()

    session =
      start(script([{:error, overloaded()}, {:ok, asst("done")}]), cwd: cwd, persist: true)

    :ok = Elara.subscribe(session)

    assert {:ok, "done"} = Elara.ask(session, "hi")

    assert_receive {:elara, ^session,
                    {:provider_retry,
                     %{attempt: 2, max_attempts: 3, delay_ms: 10, error: %Provider.Error{}}}},
                   1_000

    assert [%Message.User{text: "hi"}, %Message.Assistant{text: "done"}] =
             Elara.transcript(session)

    {:ok, info} = Store.newest(cwd)
    {:ok, store} = Store.open(info.path, cwd)

    assert [%Message.User{text: "hi"}, %Message.Assistant{text: "done"}] = Store.history(store)
  end

  test "exhausted attempts surface the final provider error" do
    session =
      start(
        script([
          {:error, overloaded()},
          {:error, overloaded()},
          {:error, %Provider.Error{kind: :http, status: 503, message: "503 last"}}
        ]),
        []
      )

    assert {:error, {:provider_error, %Provider.Error{message: "503 last"}}} =
             Elara.ask(session, "hi")

    assert [%Message.User{text: "hi"}] = Elara.transcript(session)
  end

  test "a server Retry-After is waited out before the next attempt" do
    error = %Provider.Error{
      kind: :http,
      status: 429,
      message: "429 slow down",
      retry_after_ms: 250
    }

    session =
      start(script([{:error, error}, {:ok, asst("done")}]),
        provider_retry: [max_attempts: 2, base_delay_ms: 10]
      )

    started = System.monotonic_time(:millisecond)
    assert {:ok, "done"} = Elara.ask(session, "hi")

    assert System.monotonic_time(:millisecond) - started >= 250
  end

  test "a terminal failure is not retried and leaves the rest of the script unused" do
    session = start(script([{:error, unauthorized()}, {:ok, asst("never asked")}]), [])

    assert {:error, {:provider_error, %Provider.Error{status: 401}}} = Elara.ask(session, "hi")

    # The untouched entry answers the next turn, proving the failed turn did not replay.
    assert {:ok, "never asked"} = Elara.ask(session, "again")
  end

  test "a failure after streamed output is surfaced without replaying the attempt" do
    session =
      start(
        script([
          {:stream, ["partial"], {:error, overloaded()}},
          {:ok, asst("not a replay")}
        ]),
        []
      )

    :ok = Elara.subscribe(session)

    assert {:error, {:provider_error, %Provider.Error{status: 503}}} = Elara.ask(session, "hi")
    refute_received {:elara, ^session, {:provider_retry, _}}

    assert [%Message.User{text: "hi"}] = Elara.transcript(session)
    assert {:ok, "not a replay"} = Elara.ask(session, "again")
  end

  test "interrupting a pending backoff ends the turn promptly" do
    error = %Provider.Error{
      kind: :http,
      status: 429,
      message: "429 slow down",
      retry_after_ms: 30_000
    }

    session = start(script([{:error, error}, {:ok, asst("never asked")}]), [])
    :ok = Elara.subscribe(session)
    :ok = Elara.ask_async(session, "hi")

    assert_receive {:elara, ^session, {:provider_retry, %{delay_ms: 30_000}}}, 1_000
    assert %{phase: {:awaiting_retry, _, _, 2, 30_000}} = Elara.status(session)

    started = System.monotonic_time(:millisecond)
    :ok = Elara.interrupt(session)

    assert_receive {:elara, ^session, {:turn_ended, :interrupted}}, 1_000
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert %{phase: :idle} = Elara.status(session)
    assert [%Message.User{text: "hi"}] = Elara.transcript(session)
  end

  test "a retry around a tool call leaves exactly one result per call" do
    call = %ToolCall{id: "call-1", name: "echo", args: {:ok, %{}}}

    session =
      start(
        script([
          {:ok, asst(nil, [call])},
          {:error, overloaded()},
          {:ok, asst("after tool")}
        ]),
        tools: [tool()]
      )

    assert {:ok, "after tool"} = Elara.ask(session, "hi")

    transcript = Elara.transcript(session)
    results = Enum.filter(transcript, &is_struct(&1, Message.ToolResult))

    assert Enum.map(results, & &1.call_id) == ["call-1"]

    assert Enum.count(transcript, fn
             %Message.Assistant{tool_calls: calls} -> calls != []
             _ -> false
           end) == 1
  end

  test "attached clients see the awaiting_retry turn state with its attempt and delay" do
    session =
      start(script([{:error, overloaded()}, {:ok, asst("done")}]),
        provider_retry: [max_attempts: 2, base_delay_ms: 150, max_delay_ms: 150]
      )

    {:ok, _attached} = Elara.attach(session, :observe)
    :ok = Elara.ask_async(session, "hi")

    assert_receive {:elara_patch, ^session, _incarnation, _seq, ops}, 2_000
    turn_states = collect_turn_states([ops], session)

    assert %{
             "state" => "awaiting_retry",
             "iteration" => 1,
             "attempt" => 2,
             "delay_ms" => 150
           } in turn_states
  end

  test "the retry path serves every provider, including the simulated one" do
    provider =
      Simulated.new(
        seed: 1343,
        id: "retry",
        profile: [ttft_ms: 0, errors: %{rate_limited: 1.0}]
      )

    session = start(provider, [])

    assert {:error, {:provider_error, %Provider.Error{status: 429}}} = Elara.ask(session, "hi")
  end

  test "retries can be switched off per session" do
    session =
      start(script([{:error, overloaded()}, {:ok, asst("never asked")}]),
        provider_retry: Retry.disabled()
      )

    assert {:error, {:provider_error, %Provider.Error{status: 503}}} = Elara.ask(session, "hi")
  end

  test "a retried turn replays deterministically from its recording" do
    session = start(script([{:error, overloaded()}, {:ok, asst("done")}]), [])

    assert {:ok, "done"} = Elara.ask(session, "hi")

    recording = Elara.recording(session)

    assert Enum.map(recording.transitions, & &1.fact.kind) == [
             :ask,
             :provider_result,
             :retry_elapsed,
             :provider_result
           ]

    assert {:ok, %Elara.FlightRecorder.Report{status: :match}} = Elara.replay(recording)
  end

  # Drain whatever patches have arrived and keep every turn state they set.
  defp collect_turn_states(batches, session) do
    receive do
      {:elara_patch, ^session, _incarnation, _seq, ops} ->
        collect_turn_states([ops | batches], session)
    after
      500 ->
        batches
        |> Enum.reverse()
        |> Enum.concat()
        |> Enum.filter(&(&1["op"] == "set_turn_state"))
        |> Enum.map(& &1["turn"])
    end
  end
end
