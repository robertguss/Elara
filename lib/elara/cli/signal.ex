defmodule Elara.CLI.Signal do
  @moduledoc false

  @doc """
  Block until SIGTERM.

  Elixir cannot trap SIGINT (`System.trap_signal/2` rejects it), so Mix
  tasks should be started as `elixir --erl "+Bc" -S mix ...` when Ctrl-C
  must terminate the VM instead of opening the BREAK menu. SIGTERM still
  stops the task cleanly when the OS sends `kill`.
  """
  @spec await_shutdown() :: :ok
  def await_shutdown do
    parent = self()

    _ =
      System.trap_signal(:sigterm, fn ->
        send(parent, :shutdown)
        :ok
      end)

    receive do
      :shutdown -> :ok
    end
  end

  @doc "VM flags that make Ctrl-C terminate instead of opening BREAK."
  @spec erl_no_break() :: String.t()
  def erl_no_break, do: "+Bc"
end
