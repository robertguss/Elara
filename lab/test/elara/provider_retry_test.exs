defmodule Elara.Lab.ProviderRetryTest do
  use ExUnit.Case, async: false

  test "the product retry path also serves the simulated provider" do
    provider =
      Elara.Provider.Simulated.new(
        seed: 1343,
        id: "retry",
        profile: [ttft_ms: 0, errors: %{rate_limited: 1.0}]
      )

    {:ok, session} =
      Elara.start_session(
        provider: provider,
        tools: [],
        plugins: [],
        persist: false,
        provider_retry: [max_attempts: 3, base_delay_ms: 10, max_delay_ms: 20]
      )

    assert {:error, {:provider_error, %Elara.Provider.Error{status: 429}}} =
             Elara.ask(session, "hi")
  end
end
