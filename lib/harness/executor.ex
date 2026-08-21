defmodule Harness.Executor do
  @moduledoc "Serializable tool-execution boundary."

  defmodule Request do
    @moduledoc "A placement-independent, serializable tool request."

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            session_id: String.t(),
            tool_name: String.t(),
            tool_version: String.t(),
            arguments: map(),
            workspace_id: String.t(),
            deadline_ms: integer(),
            cancellation_id: String.t(),
            required_capabilities: [String.t()],
            placement: :local | :remote | :any,
            mutating: boolean()
          }

    defstruct [
      :tool_call_id,
      :session_id,
      :tool_name,
      :tool_version,
      :arguments,
      :workspace_id,
      :deadline_ms,
      :cancellation_id,
      :required_capabilities,
      :placement,
      :mutating
    ]

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = request) do
      %{
        "tool_call_id" => request.tool_call_id,
        "session_id" => request.session_id,
        "tool_name" => request.tool_name,
        "tool_version" => request.tool_version,
        "arguments" => request.arguments,
        "workspace_id" => request.workspace_id,
        "deadline_ms" => request.deadline_ms,
        "cancellation_id" => request.cancellation_id,
        "required_capabilities" => request.required_capabilities,
        "placement" => Atom.to_string(request.placement),
        "mutating" => request.mutating
      }
    end

    @spec from_map(map()) :: {:ok, t()} | {:error, :invalid_request}
    def from_map(%{
          "tool_call_id" => call_id,
          "session_id" => session_id,
          "tool_name" => name,
          "tool_version" => version,
          "arguments" => arguments,
          "workspace_id" => workspace_id,
          "deadline_ms" => deadline,
          "cancellation_id" => cancellation_id,
          "required_capabilities" => capabilities,
          "placement" => placement,
          "mutating" => mutating
        })
        when is_binary(call_id) and is_binary(session_id) and is_binary(name) and
               is_binary(version) and is_map(arguments) and is_binary(workspace_id) and
               is_integer(deadline) and is_binary(cancellation_id) and is_list(capabilities) and
               is_boolean(mutating) do
      with {:ok, placement} <- decode_placement(placement),
           true <- Enum.all?(capabilities, &is_binary/1) do
        {:ok,
         %__MODULE__{
           tool_call_id: call_id,
           session_id: session_id,
           tool_name: name,
           tool_version: version,
           arguments: arguments,
           workspace_id: workspace_id,
           deadline_ms: deadline,
           cancellation_id: cancellation_id,
           required_capabilities: capabilities,
           placement: placement,
           mutating: mutating
         }}
      else
        _ -> {:error, :invalid_request}
      end
    end

    def from_map(_map), do: {:error, :invalid_request}

    defp decode_placement("local"), do: {:ok, :local}
    defp decode_placement("remote"), do: {:ok, :remote}
    defp decode_placement("any"), do: {:ok, :any}
    defp decode_placement(_placement), do: {:error, :invalid_request}
  end

  @type executor_error :: {:executor_error, :transport | :unavailable | :rejected, String.t()}
  @type plugin_result ::
          {:commit, Harness.Tool.outcome(), term()} | {:abort, Harness.Tool.outcome()}

  @callback execute(config :: term(), Request.t(), Harness.Tool.t()) ::
              Harness.Tool.outcome() | executor_error() | plugin_result()
end
