defmodule Elara.Provider.Scripted do
  @moduledoc """
  Test-only provider. Config is a pid holding a queue of canned provider returns.

  A stream entry has the shape `{:stream, steps, result}`. Binary steps are
  emitted as content deltas and `{:sleep, milliseconds}` steps pause the
  provider task. The result is the same `{:ok, assistant}` or `{:error, error}`
  value accepted by `chat/2`.
  """

  @behaviour Elara.Provider

  alias Elara.Provider
  alias Elara.Provider.Error

  @impl true
  def chat(agent, %Provider.Request{}) when is_pid(agent) do
    agent
    |> pop()
    |> result(agent)
  end

  @impl true
  def stream(agent, %Provider.Request{}, sink) when is_pid(agent) and is_function(sink, 1) do
    case pop(agent) do
      {:stream, steps, result} when is_list(steps) ->
        with :ok <- emit_steps(steps, sink) do
          result(result, agent)
        else
          {:error, message} ->
            {:error, %Error{kind: :bad_response, message: message}, agent}
        end

      result ->
        result(result, agent)
    end
  end

  defp pop(agent) do
    Agent.get_and_update(agent, fn
      [next | rest] -> {next, rest}
      [] -> {{:error, %Error{kind: :bad_response, message: "script exhausted"}}, []}
    end)
  end

  defp result(result, agent) do
    case result do
      {:ok, assistant} ->
        {:ok, assistant, agent}

      {:error, error} ->
        {:error, error, agent}

      other ->
        {:error, %Error{kind: :bad_response, message: "bad script entry: #{inspect(other)}"},
         agent}
    end
  end

  defp emit_steps(steps, sink) do
    Enum.reduce_while(steps, :ok, fn
      text, :ok when is_binary(text) ->
        :ok = sink.(text)
        {:cont, :ok}

      {:sleep, milliseconds}, :ok when is_integer(milliseconds) and milliseconds >= 0 ->
        Process.sleep(milliseconds)
        {:cont, :ok}

      step, :ok ->
        {:halt, {:error, "bad stream step: #{inspect(step)}"}}
    end)
  end
end
