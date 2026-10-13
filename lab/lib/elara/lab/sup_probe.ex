defmodule Elara.Lab.SupProbe do
  @moduledoc """
  One diagnostic reading of a supervisor's state and mailbox composition. A
  reading is an instant, never a verdict: it pauses the target for `read_us`
  while its mailbox is copied, and it does not say whether a waiting target's
  child was itself running.
  """

  @classes [
    :start_child,
    :which_children,
    :count_children,
    :terminate_child,
    :other_call,
    :exit,
    :other
  ]

  @frames 4
  @info [:status, :current_function, :current_stacktrace, :message_queue_len, :messages]

  @doc """
  Read `target` (a pid or registered name) from a short-lived helper, so the
  mailbox copy never stays on the caller's heap. Only the summary returns:
  `read_us`, `status`, `current_function`, the top frames, `queue_len`,
  `composition` and `run_queue`. A dead or unregistered target, a helper that
  crashes, or a helper that has not finished within `timeout_ms` (it is then
  killed) gives `%{available: false}`, never zeros.
  """
  @spec read(term(), timeout()) :: map()
  def read(target, timeout_ms \\ 5_000) do
    case resolve(target) do
      nil -> %{available: false}
      target -> read_resolved(target, timeout_ms)
    end
  end

  defp resolve(name) when is_atom(name), do: Process.whereis(name)
  defp resolve(target), do: target

  defp read_resolved(target, timeout_ms) do
    caller = self()
    ref = make_ref()

    {helper, monitor} =
      spawn_monitor(fn ->
        summary =
          try do
            summarize(target)
          catch
            _kind, _reason -> exit(:probe_failed)
          end

        send(caller, {ref, summary})
      end)

    receive do
      {:DOWN, ^monitor, :process, ^helper, _reason} ->
        run_queue = :erlang.statistics(:total_run_queue_lengths_all)

        receive do
          {^ref, %{} = summary} -> Map.merge(%{available: true, run_queue: run_queue}, summary)
          {^ref, nil} -> %{available: false}
        after
          0 -> %{available: false}
        end
    after
      timeout_ms ->
        Process.exit(helper, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^helper, _reason} -> :ok
        end

        receive do
          {^ref, _} -> :ok
        after
          0 -> :ok
        end

        %{available: false}
    end
  end

  # Runs in the helper: the only place that reads another process's `:messages`.
  defp summarize(target) do
    started = System.monotonic_time(:microsecond)
    info = Process.info(target, @info)
    finished = System.monotonic_time(:microsecond)

    case info do
      nil ->
        nil

      info ->
        %{
          read_us: finished - started,
          status: info[:status],
          current_function: mfa(info[:current_function]),
          frames: info[:current_stacktrace] |> Enum.take(@frames) |> Enum.map(&mfa/1),
          queue_len: info[:message_queue_len],
          composition: classify(info[:messages])
        }
    end
  end

  @doc "Count messages by class, retaining no payload. Pure."
  @spec classify([term()]) :: %{atom() => non_neg_integer()}
  def classify(messages) do
    Enum.reduce(messages, Map.new(@classes, &{&1, 0}), fn message, counts ->
      Map.update!(counts, class(message), &(&1 + 1))
    end)
  end

  defp class({:"$gen_call", _from, {:start_child, _spec}}), do: :start_child
  defp class({:"$gen_call", _from, :which_children}), do: :which_children
  defp class({:"$gen_call", _from, :count_children}), do: :count_children
  defp class({:"$gen_call", _from, {:terminate_child, _pid}}), do: :terminate_child
  defp class({:"$gen_call", _from, _request}), do: :other_call
  defp class({:EXIT, _pid, _reason}), do: :exit
  defp class(_message), do: :other

  @doc "A frame or function as `Mod.fun/arity`, with no arguments or location."
  @spec mfa(term()) :: String.t()
  def mfa({module, function, arity}) when is_integer(arity),
    do: Exception.format_mfa(module, function, arity)

  def mfa({module, function, arity, _location}), do: mfa({module, function, arity})
  def mfa(_other), do: "unknown"
end
