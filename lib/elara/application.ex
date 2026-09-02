defmodule Elara.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Elara.SessionLocks},
      {Registry, keys: :unique, name: Elara.Sessions},
      {Registry, keys: :unique, name: Elara.EffectExecutors},
      {Task.Supervisor, name: Elara.TaskSup},
      {Elara.Executor.Router, name: Elara.Executor.Router},
      {DynamicSupervisor, name: Elara.EffectExecutorSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Elara.PluginSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Elara.SessionSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Elara.CoordinatorSup, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Elara.Supervisor)
  end
end
