defmodule Elara.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Elara.SessionLocks},
      {Registry, keys: :unique, name: Elara.Sessions},
      {Registry, keys: :unique, name: Elara.EffectExecutors},
      {Registry, keys: :unique, name: Elara.ThreadSlots},
      Elara.Exec,
      {Task.Supervisor, name: Elara.TaskSup},
      {Elara.Executor.Router, name: Elara.Executor.Router},
      {DynamicSupervisor, name: Elara.EffectExecutorSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Elara.PluginSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Elara.SessionSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Elara.CoordinatorSup, strategy: :one_for_one},
      Elara.Threads,
      Elara.Threads.Communication,
      Elara.TestJobs
    ]

    # Production keeps OTP's default intensity. The test config raises it because
    # crash-recovery tests deliberately kill supervised singletons in sequence.
    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Elara.Supervisor,
      max_restarts: Application.get_env(:elara, :max_restarts, 3)
    )
  end
end
