defmodule Elara.Executor.Local do
  @moduledoc false

  @behaviour Elara.Executor

  alias Elara.Executor.Request
  alias Elara.Tool
  alias Elara.Tool.Ctx

  @impl true
  def execute(%{cwd: cwd}, %Request{} = request, %Tool{run: {module, function}} = tool) do
    ctx = %Ctx{
      session_id: request.session_id,
      cwd: cwd,
      plugin: tool.plugin,
      tool_name: request.tool_name,
      job_id: request.job_id,
      operation_digest: request.operation_digest,
      max_output_bytes: request.max_output_bytes,
      timeout_ms: max(request.deadline_ms - System.system_time(:millisecond), 1)
    }

    apply(module, function, [request.arguments, ctx])
  end
end
