defmodule Elara.Protocol.Projector do
  @moduledoc false

  alias Elara.Protocol

  @enforce_keys [:view, :incarnation, :head]
  defstruct [:view, :incarnation, :head, awaiting_snapshot?: false]

  @type t :: %__MODULE__{
          view: map(),
          incarnation: String.t(),
          head: non_neg_integer(),
          awaiting_snapshot?: boolean()
        }

  @spec new(map(), String.t(), non_neg_integer()) :: t()
  def new(view, incarnation, head)
      when is_map(view) and is_binary(incarnation) and is_integer(head) and head >= 0 do
    %__MODULE__{view: view, incarnation: incarnation, head: head}
  end

  @spec install_snapshot(t(), map(), String.t(), non_neg_integer()) :: t()
  def install_snapshot(projector, view, incarnation, head)
      when is_map(view) and is_binary(incarnation) and is_integer(head) and head >= 0 do
    %{projector | view: view, incarnation: incarnation, head: head, awaiting_snapshot?: false}
  end

  @spec ingest_patch(t(), String.t(), non_neg_integer(), [map()]) ::
          {:applied | :ignored | :resnapshot, t()}
  def ingest_patch(%__MODULE__{awaiting_snapshot?: true} = projector, _incarnation, _seq, _ops),
    do: {:ignored, projector}

  def ingest_patch(%__MODULE__{} = projector, incarnation, seq, ops)
      when is_binary(incarnation) and is_integer(seq) and seq >= 0 and is_list(ops) do
    cond do
      incarnation != projector.incarnation ->
        request_resnapshot(projector)

      seq <= projector.head ->
        {:ignored, projector}

      seq != projector.head + 1 ->
        request_resnapshot(projector)

      true ->
        case Protocol.apply_patch(projector.view, ops) do
          {:ok, view} -> {:applied, %{projector | view: view, head: seq}}
          {:error, :invalid_patch} -> request_resnapshot(projector)
        end
    end
  end

  def ingest_patch(%__MODULE__{} = projector, _incarnation, _seq, _ops),
    do: request_resnapshot(projector)

  defp request_resnapshot(projector),
    do: {:resnapshot, %{projector | awaiting_snapshot?: true}}
end
