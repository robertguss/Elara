defmodule Harness.Executor.PluginLocal do
  @moduledoc false

  @behaviour Harness.Executor

  alias Harness.Executor.Request

  @impl true
  def execute(config, %Request{} = request, _tool) do
    Harness.Plugin.invoke(
      config.module,
      request.tool_name,
      request.arguments,
      config.ctx,
      config.plugin_state
    )
  end
end
