defmodule Harness.Executor.Local do
  @moduledoc false

  @behaviour Harness.Executor

  alias Harness.Executor.Request
  alias Harness.Tool
  alias Harness.Tool.Ctx

  @impl true
  def execute(%{cwd: cwd}, %Request{} = request, %Tool{run: {module, function}} = tool) do
    ctx = %Ctx{cwd: cwd, plugin: tool.plugin, tool_name: request.tool_name}
    apply(module, function, [request.arguments, ctx])
  end
end
