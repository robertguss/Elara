defmodule Elara.Provider.RetryTest do
  @moduledoc "ROB-1343: the pure retry policy. Classification, bounds and Retry-After."
  use ExUnit.Case, async: true

  alias Elara.Provider.Error
  alias Elara.Provider.Retry
  alias Elara.Provider.Retry.Policy

  defp http(status, opts \\ []),
    do: struct!(%Error{kind: :http, status: status, message: "#{status}"}, opts)

  describe "classification" do
    test "retryable HTTP statuses are the overload and gateway family" do
      for status <- [408, 425, 429, 500, 502, 503, 504, 509, 529] do
        assert Retry.retryable?(http(status)), "#{status} should be retryable"
      end
    end

    test "client and entitlement failures are terminal" do
      for status <- [400, 401, 403, 404, 409, 413, 422] do
        refute Retry.retryable?(http(status)), "#{status} should be terminal"
      end
    end

    test "a transport failure is retryable and other kinds are not" do
      assert Retry.retryable?(%Error{kind: :transport, message: "closed"})

      for kind <- [:bad_response, :crash, :entitlement, :resource_limit] do
        refute Retry.retryable?(%Error{kind: kind, message: "x"}), "#{kind} should be terminal"
      end
    end

    test "an HTTP failure with no status is terminal rather than guessed" do
      refute Retry.retryable?(%Error{kind: :http, message: "no status"})
    end
  end

  describe "backoff" do
    test "delays double per failed attempt and keep equal jitter" do
      policy = Retry.new(max_attempts: 5, base_delay_ms: 100, max_delay_ms: 10_000)

      assert {:retry, %{min_ms: 50, max_ms: 100}} = Retry.schedule(policy, 1, 0, http(503))
      assert {:retry, %{min_ms: 100, max_ms: 200}} = Retry.schedule(policy, 2, 100, http(503))
      assert {:retry, %{min_ms: 200, max_ms: 400}} = Retry.schedule(policy, 3, 300, http(503))
    end

    test "the per-delay cap bounds growth" do
      policy = Retry.new(max_attempts: 9, base_delay_ms: 100, max_delay_ms: 250)

      assert {:retry, %{max_ms: 250}} = Retry.schedule(policy, 4, 0, http(503))
    end

    test "max_attempts counts the first attempt" do
      policy = Retry.new(max_attempts: 2, base_delay_ms: 10)

      assert {:retry, _} = Retry.schedule(policy, 1, 0, http(503))
      assert :stop = Retry.schedule(policy, 2, 10, http(503))
    end

    test "the total wait budget clamps the last delay and then stops" do
      policy = Retry.new(max_attempts: 9, base_delay_ms: 100, max_total_wait_ms: 250)

      assert {:retry, %{min_ms: 50, max_ms: 100}} = Retry.schedule(policy, 1, 0, http(503))
      assert {:retry, %{min_ms: 75, max_ms: 150}} = Retry.schedule(policy, 2, 100, http(503))
      assert :stop = Retry.schedule(policy, 3, 250, http(503))
    end

    test "disabled/0 never retries and default/0 does" do
      assert :stop = Retry.schedule(Retry.disabled(), 1, 0, http(503))
      assert {:retry, _} = Retry.schedule(Retry.default(), 1, 0, http(503))
    end

    test "a terminal error is never scheduled, whatever the budget" do
      assert :stop = Retry.schedule(Retry.default(), 1, 0, http(401))
    end
  end

  describe "Retry-After" do
    test "a server delay replaces the computed window exactly" do
      policy = Retry.new(max_attempts: 5, base_delay_ms: 100)
      error = http(429, retry_after_ms: 2_000)

      assert {:retry, %{min_ms: 2_000, max_ms: 2_000}} = Retry.schedule(policy, 1, 0, error)
    end

    test "a server delay past the remaining budget is refused, not shortened" do
      policy = Retry.new(max_attempts: 5, base_delay_ms: 100, max_total_wait_ms: 1_000)

      assert :stop = Retry.schedule(policy, 1, 0, http(429, retry_after_ms: 1_001))
    end

    test "a server delay on a terminal status is still not retried" do
      assert :stop = Retry.schedule(Retry.default(), 1, 0, http(403, retry_after_ms: 10))
    end

    test "delay-seconds parse to milliseconds and anything else is nil" do
      assert Retry.parse_retry_after("30") == 30_000
      assert Retry.parse_retry_after(" 0 ") == 0
      assert Retry.parse_retry_after(nil) == nil
      assert Retry.parse_retry_after("") == nil
      assert Retry.parse_retry_after("-1") == nil
      assert Retry.parse_retry_after("soon") == nil
      assert Retry.parse_retry_after("Wed, 21 Oct 2026 07:28:00 GMT") == nil
    end

    test "from_response reads the header off a response" do
      response = %Req.Response{status: 429, headers: %{"retry-after" => ["7"]}}

      assert Retry.from_response(response) == 7_000
      assert Retry.from_response(%Req.Response{status: 429}) == nil
    end
  end

  describe "configuration" do
    test "the environment overrides attempts and total wait" do
      policy =
        Retry.from_env(%{
          "ELARA_PROVIDER_RETRY_ATTEMPTS" => "2",
          "ELARA_PROVIDER_RETRY_MAX_WAIT_MS" => "1500"
        })

      assert %Policy{max_attempts: 2, max_total_wait_ms: 1_500} = policy
      assert policy.base_delay_ms == Retry.default().base_delay_ms
    end

    test "an empty or unreadable environment keeps the defaults" do
      assert Retry.from_env(%{}) == Retry.default()
      assert Retry.from_env(%{"ELARA_PROVIDER_RETRY_ATTEMPTS" => "many"}) == Retry.default()
    end

    test "new/1 refuses a policy that cannot bound the wait" do
      assert_raise ArgumentError, fn -> Retry.new(max_attempts: 0) end
      assert_raise ArgumentError, fn -> Retry.new(base_delay_ms: 0) end
      assert_raise ArgumentError, fn -> Retry.new(base_delay_ms: 500, max_delay_ms: 100) end
      assert_raise ArgumentError, fn -> Retry.new(max_total_wait_ms: -1) end
    end
  end
end
