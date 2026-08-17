defmodule Harness.Provider.Scripted do
  @moduledoc "Test-only provider. Config is a pid holding a queue of canned chat/2 returns."

  @behaviour Harness.Provider

  alias Harness.Provider
  alias Harness.Provider.Error

  @impl true
  def chat(agent, %Provider.Request{}) when is_pid(agent) do
    case Agent.get_and_update(agent, fn
           [next | rest] -> {next, rest}
           [] -> {{:error, %Error{kind: :bad_response, message: "script exhausted"}}, []}
         end) do
      {:ok, assistant} ->
        {:ok, assistant, agent}

      {:error, error} ->
        {:error, error, agent}

      other ->
        {:error, %Error{kind: :bad_response, message: "bad script entry: #{inspect(other)}"},
         agent}
    end
  end
end
