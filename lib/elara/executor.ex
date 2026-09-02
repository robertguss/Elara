defmodule Elara.Executor do
  @moduledoc "Serializable tool-execution boundary."

  defmodule Request do
    @moduledoc "A placement-independent, serializable tool request."

    @type t :: %__MODULE__{
            job_id: String.t() | nil,
            operation_digest: String.t() | nil,
            tool_call_id: String.t(),
            session_id: String.t(),
            tool_name: String.t(),
            tool_version: String.t(),
            arguments: map(),
            workspace_id: String.t(),
            deadline_ms: integer(),
            max_output_bytes: pos_integer(),
            cancellation_id: String.t(),
            required_capabilities: [String.t()],
            placement: :local | :remote | :any,
            mutating: boolean()
          }

    defstruct [
      :job_id,
      :operation_digest,
      :tool_call_id,
      :session_id,
      :tool_name,
      :tool_version,
      :arguments,
      :workspace_id,
      :deadline_ms,
      :max_output_bytes,
      :cancellation_id,
      :required_capabilities,
      :placement,
      :mutating
    ]

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = request) do
      %{
        "job_id" => request.job_id,
        "operation_digest" => request.operation_digest,
        "tool_call_id" => request.tool_call_id,
        "session_id" => request.session_id,
        "tool_name" => request.tool_name,
        "tool_version" => request.tool_version,
        "arguments" => request.arguments,
        "workspace_id" => request.workspace_id,
        "deadline_ms" => request.deadline_ms,
        "max_output_bytes" => request.max_output_bytes,
        "cancellation_id" => request.cancellation_id,
        "required_capabilities" => request.required_capabilities,
        "placement" => Atom.to_string(request.placement),
        "mutating" => request.mutating
      }
    end

    @spec from_map(map()) :: {:ok, t()} | {:error, :invalid_request}
    def from_map(
          %{
            "tool_call_id" => call_id,
            "session_id" => session_id,
            "tool_name" => name,
            "tool_version" => version,
            "arguments" => arguments,
            "workspace_id" => workspace_id,
            "deadline_ms" => deadline,
            "max_output_bytes" => max_output_bytes,
            "cancellation_id" => cancellation_id,
            "required_capabilities" => capabilities,
            "placement" => placement,
            "mutating" => mutating
          } = encoded
        )
        when is_binary(call_id) and is_binary(session_id) and is_binary(name) and
               is_binary(version) and is_map(arguments) and is_binary(workspace_id) and
               is_integer(deadline) and is_integer(max_output_bytes) and max_output_bytes > 0 and
               is_binary(cancellation_id) and is_list(capabilities) and is_boolean(mutating) do
      job_id = Map.get(encoded, "job_id")
      operation_digest = Map.get(encoded, "operation_digest")

      with {:ok, placement} <- decode_placement(placement),
           true <- Enum.all?(capabilities, &is_binary/1),
           true <- valid_job_identity?(job_id, operation_digest) do
        {:ok,
         %__MODULE__{
           job_id: job_id,
           operation_digest: operation_digest,
           tool_call_id: call_id,
           session_id: session_id,
           tool_name: name,
           tool_version: version,
           arguments: arguments,
           workspace_id: workspace_id,
           deadline_ms: deadline,
           max_output_bytes: max_output_bytes,
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

    defp valid_job_identity?(nil, nil), do: true

    defp valid_job_identity?(job_id, operation_digest),
      do: is_binary(job_id) and job_id != "" and valid_digest?(operation_digest)

    defp valid_digest?(digest) when is_binary(digest) and byte_size(digest) == 64 do
      String.match?(digest, ~r/\A[0-9a-f]{64}\z/)
    end

    defp valid_digest?(_digest), do: false
  end

  @type executor_error :: {:executor_error, :transport | :unavailable | :rejected, String.t()}
  @type plugin_result ::
          {:commit, Elara.Tool.outcome(), term()} | {:abort, Elara.Tool.outcome()}

  @callback execute(config :: term(), Request.t(), Elara.Tool.t()) ::
              Elara.Tool.outcome() | executor_error() | plugin_result()
end
