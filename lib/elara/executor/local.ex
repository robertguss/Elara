defmodule Elara.Executor.Local do
  @moduledoc false

  @behaviour Elara.Executor

  alias Elara.Executor.Request
  alias Elara.Tool
  alias Elara.Tool.Ctx

  @impl true
  def execute(%{cwd: cwd}, %Request{} = request, %Tool{run: {module, function}} = tool) do
    ctx = %Ctx{cwd: cwd, plugin: tool.plugin, tool_name: request.tool_name}
    apply(module, function, [request.arguments, ctx])
  end
end
