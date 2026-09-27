defmodule Elara.Provider.Simulated do
  @moduledoc """
  Seeded simulated provider for lab runs. Choices are deterministic per session;
  latency is real wall-clock time. Not a model: it answers any request.

  Each request makes one choice from the config's own random state, which the
  session carries forward in the returned config:

    * `{:error, kind}`: an injected 429, 5xx, or disconnect before or after the
      first streamed byte.
    * `{:tool, name}`: a tool call from the cycled `tool_plan`, until
      `tool_rounds` calls follow the latest user message.
    * `:answer`: `answer_deltas` streamed deltas of `delta_bytes` each.
    * `{:rule, index}`: the first of the profile's `rules` whose predicate
      accepts the request's messages. A rule's response is `{:tool, name, args}`,
      `{:error, %Provider.Error{}}` or `:answer`. Rules script specific requests
      (a fault after one tool result, a status call on completion).

  Each request takes exactly one draw from the choice stream; answer text comes
  from a separate per-request state seeded by `(seed, id, request)`. So a rule
  that replaces a request does not shift later choices or text.

  Deltas follow an intended schedule: `ttft_ms` after the request starts, then
  one every `1000 / deltas_per_sec` ms. A late delta keeps its intended time, so
  scheduler delay stays measurable. With a `collector` pid, the provider sends
  `{:lab_choice, id, request, choice}` and
  `{:lab_delta, id, request, index, intended_ms}` (monotonic milliseconds).

  A request whose provider task dies never returns its config, so the session
  retries with the same request number and random state, and repeats the choice.

  An optional `fault` hook (see `Elara.Lab.Faults`) is called at
  `:provider_started` and, after the first delta, `:provider_streaming`, with
  the key `"id:request"`. Tool-plan arguments equal to `"$key"` receive that key.
  """

  @behaviour Elara.Provider

  alias Elara.Message
  alias Elara.Message.{Assistant, ToolCall, User}
  alias Elara.Provider
  alias Elara.Provider.Error

  @defaults %{
    ttft_ms: 300,
    deltas_per_sec: 50,
    delta_bytes: 20,
    answer_deltas: 20,
    tool_rounds: 2,
    tool_plan: [],
    rules: [],
    errors: %{rate_limited: 0.0, server_error: 0.0, disconnect_before: 0.0, disconnect_after: 0.0}
  }

  defstruct [:id, :seed, :rand, :profile, :collector, :fault, requests: 0]

  @type t :: %__MODULE__{}

  @doc """
  Build a provider spec. `seed` and `id` together fix the random stream, so the
  same run seed gives each session index the same choices.
  """
  @spec new(keyword()) :: {module(), t()}
  def new(opts) do
    seed = Keyword.fetch!(opts, :seed)
    id = Keyword.fetch!(opts, :id)
    profile = Map.merge(@defaults, Map.new(Keyword.get(opts, :profile, [])))
    profile = %{profile | errors: Map.merge(@defaults.errors, Map.new(profile.errors))}
    rand = :rand.seed_s(:exsss, {seed, :erlang.phash2(id), 0x9E3779B9})

    {__MODULE__,
     %__MODULE__{
       id: id,
       seed: seed,
       rand: rand,
       profile: profile,
       collector: Keyword.get(opts, :collector),
       fault: Keyword.get(opts, :fault)
     }}
  end

  @impl true
  def chat(config, %Provider.Request{} = request), do: stream(config, request, fn _ -> :ok end)

  @impl true
  def stream(%__MODULE__{} = config, %Provider.Request{} = request, sink) do
    started = System.monotonic_time(:millisecond)
    number = config.requests + 1
    {choice, rand} = choose(config, request.messages)
    config = %{config | rand: rand, requests: number}
    notify(config, {:lab_choice, config.id, number, choice})
    fault(config, :provider_started, number)

    case response(config, choice) do
      {:error, %Error{} = error} -> {:error, error, config}
      {:error, kind} -> error(config, kind, started, number, sink)
      {:tool, name, args} -> tool_call(config, name, args, started, number)
      {:tool, _name} -> tool_call(config, request.messages, started, number)
      :answer -> answer(config, started, number, sink)
    end
  end

  # ── Choices ─────────────────────────────────────────────────────────────

  defp choose(config, messages) do
    {roll, rand} = :rand.uniform_s(config.rand)

    case Enum.find_index(config.profile.rules, fn {matches?, _} -> matches?.(messages) end) do
      nil -> {seeded_choice(config, messages, roll), rand}
      index -> {{:rule, index}, rand}
    end
  end

  defp seeded_choice(config, messages, roll) do
    errors = config.profile.errors

    thresholds = [
      rate_limited: errors.rate_limited,
      server_error: errors.server_error,
      disconnect_before: errors.disconnect_before,
      disconnect_after: errors.disconnect_after
    ]

    case injected_error(thresholds, roll, 0.0) do
      nil ->
        rounds = tool_rounds_since_user(messages)
        plan = config.profile.tool_plan

        if plan != [] and rounds < config.profile.tool_rounds do
          {name, _args} = Enum.at(plan, rem(rounds, length(plan)))
          {:tool, name}
        else
          :answer
        end

      kind ->
        {:error, kind}
    end
  end

  defp response(config, {:rule, index}), do: config.profile.rules |> Enum.at(index) |> elem(1)
  defp response(_config, choice), do: choice

  defp injected_error([], _roll, _acc), do: nil

  defp injected_error([{kind, rate} | rest], roll, acc) do
    if roll < acc + rate, do: kind, else: injected_error(rest, roll, acc + rate)
  end

  defp tool_rounds_since_user(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&(not match?(%User{}, &1)))
    |> Enum.count(&match?(%Assistant{tool_calls: [_ | _]}, &1))
  end

  # ── Responses ───────────────────────────────────────────────────────────

  defp tool_call(config, messages, started, number) do
    rounds = tool_rounds_since_user(messages)
    plan = config.profile.tool_plan
    {name, args} = Enum.at(plan, rem(rounds, length(plan)))
    tool_call(config, name, args, started, number)
  end

  defp tool_call(config, name, args, started, number) do
    sleep_until(started + config.profile.ttft_ms)
    args = Map.new(args, fn {k, v} -> {k, if(v == "$key", do: key(config, number), else: v)} end)
    call = %ToolCall{id: "sim-#{config.id}-#{number}", name: name, args: {:ok, args}}
    {:ok, assistant} = Message.assistant(nil, [call])
    {:ok, assistant, config}
  end

  defp answer(config, started, number, sink) do
    {text, config} = stream_deltas(config, started, number, config.profile.answer_deltas, sink)
    {:ok, assistant} = Message.assistant(text, [])
    {:ok, assistant, config}
  end

  defp error(config, :rate_limited, _started, _number, _sink),
    do: {:error, %Error{kind: :http, status: 429, message: "simulated rate limit"}, config}

  defp error(config, :server_error, _started, _number, _sink),
    do: {:error, %Error{kind: :http, status: 503, message: "simulated server error"}, config}

  defp error(config, :disconnect_before, started, _number, _sink) do
    sleep_until(started + config.profile.ttft_ms)
    {:error, %Error{kind: :transport, message: "simulated disconnect before first byte"}, config}
  end

  defp error(config, :disconnect_after, started, number, sink) do
    count = max(div(config.profile.answer_deltas, 2), 1)
    {_text, config} = stream_deltas(config, started, number, count, sink)
    {:error, %Error{kind: :transport, message: "simulated disconnect mid-stream"}, config}
  end

  defp stream_deltas(config, started, number, count, sink) do
    interval = 1000 / config.profile.deltas_per_sec
    text_rand = :rand.seed_s(:exsss, {config.seed, :erlang.phash2(config.id), number})

    {parts, _rand} =
      Enum.map_reduce(0..(count - 1)//1, text_rand, fn index, rand ->
        {part, rand} = delta_text(rand, config.profile.delta_bytes)
        intended = started + config.profile.ttft_ms + round(index * interval)
        sleep_until(intended)
        notify(config, {:lab_delta, config.id, number, index, intended})
        :ok = sink.(part)
        if index == 0, do: fault(config, :provider_streaming, number)
        {part, rand}
      end)

    {Enum.join(parts), config}
  end

  @alphabet ~c"abcdefghijklmnopqrstuvwxyz "

  defp delta_text(rand, bytes) do
    {chars, rand} =
      Enum.map_reduce(1..bytes//1, rand, fn _, rand ->
        {i, rand} = :rand.uniform_s(length(@alphabet), rand)
        {Enum.at(@alphabet, i - 1), rand}
      end)

    {List.to_string(chars), rand}
  end

  defp sleep_until(target) do
    remaining = target - System.monotonic_time(:millisecond)
    if remaining > 0, do: Process.sleep(remaining)
    :ok
  end

  # Fault points use the key "id:request", which a "$key" tool argument also receives.
  defp key(config, number), do: "#{config.id}:#{number}"

  defp fault(%__MODULE__{fault: nil}, _point, _number), do: :ok

  defp fault(%__MODULE__{fault: hook} = config, point, number),
    do: hook.(point, key(config, number))

  defp notify(%__MODULE__{collector: nil}, _message), do: :ok
  defp notify(%__MODULE__{collector: pid}, message), do: send(pid, message)
end
