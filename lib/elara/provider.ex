defmodule Elara.Provider do
  @moduledoc """
  The LLM boundary. HTTP and vendor JSON die behind chat/2.
  """

  defmodule Request do
    @type t :: %__MODULE__{
            system: String.t(),
            messages: [Elara.Message.t()],
            tools: [Elara.Tool.t()]
          }
    defstruct [:system, :messages, :tools]
  end

  defmodule Error do
    @type kind :: :http | :transport | :bad_response | :crash | :entitlement
    @type t :: %__MODULE__{kind: kind(), message: String.t(), status: integer() | nil}
    defstruct [:kind, :message, status: nil]
  end

  @type config :: term()

  @callback chat(config(), Request.t()) ::
              {:ok, Elara.Message.Assistant.t(), config()}
              | {:error, Error.t(), config()}
end
