defmodule Elara.Executor.PluginLocal do
  @moduledoc false

  @behaviour Elara.Executor

  alias Elara.Executor.Request

  @impl true
  def execute(config, %Request{} = request, _tool) do
    Elara.Plugin.invoke(
      config.module,
      request.tool_name,
      request.arguments,
      config.ctx,
      config.plugin_state
    )
  end
end
