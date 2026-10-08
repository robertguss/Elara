defmodule Elara.Provider.Retry do
  @moduledoc """
  Transient-failure policy for provider calls. Pure: it classifies an error and
  sizes a backoff window. It never waits, never calls a provider, and never
  decides whether an attempt already emitted output — `Elara.Session.Core` owns
  that and `Elara.Session` owns the wait.

  Classification is structural, from `Elara.Provider.Error` kind and status, not
  from message text. A retryable failure is one the same request may survive:
  a retryable HTTP status, or a transport error. Authentication, entitlement,
  invalid request, context limits, malformed responses and provider-task crashes
  are terminal, so they surface immediately.
  """

  alias Elara.Provider.Error

  @retryable_statuses [408, 425, 429, 500, 502, 503, 504, 509, 529]

  defmodule Policy do
    @moduledoc "Bounds on provider retries. `max_attempts` counts the first attempt."
    @type t :: %__MODULE__{
            max_attempts: pos_integer(),
            base_delay_ms: pos_integer(),
            max_delay_ms: pos_integer(),
            max_total_wait_ms: non_neg_integer()
          }
    defstruct max_attempts: 4,
              base_delay_ms: 500,
              max_delay_ms: 8_000,
              max_total_wait_ms: 60_000
  end

  @type window :: %{min_ms: non_neg_integer(), max_ms: non_neg_integer()}

  @doc "The shipped defaults: four attempts, exponential 500ms base, one minute of total wait."
  @spec default() :: Policy.t()
  def default, do: %Policy{}

  @doc "A policy that never retries, so the first failure surfaces unchanged."
  @spec disabled() :: Policy.t()
  def disabled, do: %Policy{max_attempts: 1, max_total_wait_ms: 0}

  @doc """
  Build a policy from options, raising on values that would unbound the wait.
  `max_attempts: 1` disables retries.
  """
  @spec new(keyword()) :: Policy.t()
  def new(opts) when is_list(opts) do
    policy = struct!(Policy, opts)

    cond do
      policy.max_attempts < 1 ->
        raise ArgumentError, "max_attempts must be at least 1"

      policy.base_delay_ms < 1 ->
        raise ArgumentError, "base_delay_ms must be positive"

      policy.max_delay_ms < policy.base_delay_ms ->
        raise ArgumentError, "max_delay_ms too small"

      policy.max_total_wait_ms < 0 ->
        raise ArgumentError, "max_total_wait_ms must not be negative"

      true ->
        policy
    end
  end

  @doc """
  Read the policy from the environment, falling back to `default/0` per key.
  `ELARA_PROVIDER_RETRY_ATTEMPTS=1` turns retries off.
  """
  @spec from_env(%{String.t() => String.t()}) :: Policy.t()
  def from_env(env) when is_map(env) do
    new(
      max_attempts: integer_env(env, "ELARA_PROVIDER_RETRY_ATTEMPTS", default().max_attempts),
      max_total_wait_ms:
        integer_env(env, "ELARA_PROVIDER_RETRY_MAX_WAIT_MS", default().max_total_wait_ms)
    )
  end

  @doc "True when the same request may survive a repeat."
  @spec retryable?(Error.t()) :: boolean()
  def retryable?(%Error{kind: :http, status: status}) when is_integer(status),
    do: status in @retryable_statuses

  def retryable?(%Error{kind: :transport}), do: true
  def retryable?(%Error{}), do: false

  @doc """
  Size the wait before attempt `failed + 1`, given the attempts that already
  failed and the wait already scheduled for this provider call.

  Returns `{:retry, window}` where the caller waits uniformly inside the window;
  equal jitter spreads a retry over the upper half of the computed delay so
  concurrent sessions do not re-converge. A server-sent `Retry-After` collapses
  the window to that exact delay, and is refused rather than shortened when it
  would exceed the remaining budget: waiting less than the server asked is not
  honoring it, and waiting more than the operator allowed is not bounded.
  """
  @spec schedule(Policy.t(), pos_integer(), non_neg_integer(), Error.t()) ::
          {:retry, window()} | :stop
  def schedule(%Policy{} = policy, failed, waited_ms, %Error{} = error)
      when is_integer(failed) and failed > 0 and is_integer(waited_ms) and waited_ms >= 0 do
    remaining = policy.max_total_wait_ms - waited_ms

    cond do
      failed >= policy.max_attempts -> :stop
      not retryable?(error) -> :stop
      remaining <= 0 -> :stop
      error.retry_after_ms -> directed(error.retry_after_ms, remaining)
      true -> {:retry, jittered(policy, failed, remaining)}
    end
  end

  defp directed(retry_after_ms, remaining) when retry_after_ms <= remaining,
    do: {:retry, %{min_ms: retry_after_ms, max_ms: retry_after_ms}}

  defp directed(_retry_after_ms, _remaining), do: :stop

  defp jittered(policy, failed, remaining) do
    uncapped = policy.base_delay_ms * Integer.pow(2, failed - 1)
    max_ms = Enum.min([uncapped, policy.max_delay_ms, remaining])
    %{min_ms: div(max_ms, 2), max_ms: max_ms}
  end

  @doc "Milliseconds requested by a response's `Retry-After` header, or nil."
  @spec from_response(Req.Response.t()) :: non_neg_integer() | nil
  def from_response(%Req.Response{} = response) do
    response
    |> Req.Response.get_header("retry-after")
    |> List.first()
    |> parse_retry_after()
  end

  @doc """
  Pure `Retry-After` parse, delay-seconds form only. A missing, malformed or
  HTTP-date value is nil, never zero, so the caller's own backoff stays in
  charge rather than retrying immediately on a header we cannot read.
  """
  @spec parse_retry_after(String.t() | nil) :: non_neg_integer() | nil
  def parse_retry_after(nil), do: nil

  def parse_retry_after(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> nil
    end
  end

  defp integer_env(env, name, fallback) do
    case env |> Map.get(name, "") |> String.trim() |> Integer.parse() do
      {value, ""} -> value
      _ -> fallback
    end
  end
end
