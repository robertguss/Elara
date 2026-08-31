defmodule Elara.Effect.Job do
  @moduledoc false

  @schema_version 1
  @job_id_version 1
  @digest_version 1
  @marker_schema_version 1

  @enforce_keys [
    :job_id,
    :operation_digest,
    :effect_id,
    :operation_kind,
    :tool_name,
    :tool_version,
    :arguments,
    :workspace_id,
    :required_capabilities,
    :authority_scope
  ]
  defstruct [
    :job_id,
    :operation_digest,
    :tool_call_id,
    :effect_id,
    :operation_kind,
    :tool_name,
    :tool_version,
    :arguments,
    :workspace_id,
    :required_capabilities,
    :authority_scope,
    state: :intent,
    schema_version: @schema_version,
    job_id_version: @job_id_version,
    digest_version: @digest_version,
    marker_schema_version: @marker_schema_version
  ]

  @type effect_id :: %{
          recording_id: String.t(),
          sequence: pos_integer(),
          effect_index: non_neg_integer()
        }

  @type authority_scope :: %{
          allowed_capabilities: :all | [String.t()],
          placement: :local | :remote | :any
        }

  @type t :: %__MODULE__{
          job_id: String.t(),
          operation_digest: String.t(),
          tool_call_id: String.t() | nil,
          effect_id: effect_id(),
          operation_kind: atom(),
          tool_name: String.t(),
          tool_version: String.t(),
          arguments: map(),
          workspace_id: String.t(),
          required_capabilities: [String.t()],
          authority_scope: authority_scope(),
          state: :intent,
          schema_version: pos_integer(),
          job_id_version: pos_integer(),
          digest_version: pos_integer(),
          marker_schema_version: pos_integer()
        }

  @spec new(effect_id(), keyword()) :: t()
  def new(
        %{recording_id: recording_id, sequence: sequence, effect_index: effect_index} = effect_id,
        attrs
      )
      when is_binary(recording_id) and is_integer(sequence) and sequence > 0 and
             is_integer(effect_index) and effect_index >= 0 and is_list(attrs) do
    operation_kind = Keyword.fetch!(attrs, :operation_kind)
    tool_call_id = Keyword.get(attrs, :tool_call_id)
    tool_name = Keyword.fetch!(attrs, :tool_name)
    tool_version = Keyword.fetch!(attrs, :tool_version)
    arguments = Keyword.fetch!(attrs, :arguments)
    workspace_id = Keyword.fetch!(attrs, :workspace_id)

    required_capabilities =
      attrs |> Keyword.fetch!(:required_capabilities) |> canonical_capabilities()

    allowed_capabilities = attrs |> Keyword.fetch!(:allowed_capabilities) |> canonical_authority()
    placement = Keyword.fetch!(attrs, :placement)
    marker_schema_version = Keyword.get(attrs, :marker_schema_version, @marker_schema_version)

    authority_scope = %{
      allowed_capabilities: allowed_capabilities,
      placement: placement
    }

    job_id =
      digest({:elara_er1_job, @job_id_version, recording_id, sequence, effect_index})

    operation_digest =
      digest({
        :elara_er1_operation,
        @digest_version,
        operation_kind,
        tool_name,
        tool_version,
        arguments,
        workspace_id,
        required_capabilities,
        authority_scope,
        marker_schema_version
      })

    %__MODULE__{
      job_id: "er1j_v#{@job_id_version}_#{job_id}",
      operation_digest: operation_digest,
      tool_call_id: tool_call_id,
      effect_id: effect_id,
      operation_kind: operation_kind,
      tool_name: tool_name,
      tool_version: tool_version,
      arguments: arguments,
      workspace_id: workspace_id,
      required_capabilities: required_capabilities,
      authority_scope: authority_scope,
      marker_schema_version: marker_schema_version
    }
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  defp canonical_capabilities(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp canonical_authority(:all), do: :all
  defp canonical_authority(capabilities), do: canonical_capabilities(capabilities)

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
