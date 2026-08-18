defmodule Harness.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Harness.SessionLocks},
      {Registry, keys: :unique, name: Harness.Sessions},
      {Task.Supervisor, name: Harness.TaskSup},
      {Harness.Executor.Router, name: Harness.Executor.Router},
      {DynamicSupervisor, name: Harness.PluginSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Harness.SessionSup, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Harness.Supervisor)
  end
end
