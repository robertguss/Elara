defmodule Elara.Provider do
  @moduledoc """
  The LLM boundary. HTTP and vendor JSON die behind chat/2 and stream/3.
  """

  defmodule Request do
    @type t :: %__MODULE__{
            system: String.t(),
            messages: [Elara.Message.t()],
            tools: [Elara.Tool.t()],
            settings: Elara.Provider.Visibility.settings() | nil
          }
    defstruct [:system, :messages, :tools, :settings]
  end

  defmodule Error do
    @moduledoc """
    A failed provider call. `retry_after_ms` carries a server-sent `Retry-After`
    so the retry policy can honor it; absent means the policy picks the delay.
    """
    @type kind :: :http | :transport | :bad_response | :crash | :entitlement | :resource_limit
    @type t :: %__MODULE__{
            kind: kind(),
            message: String.t(),
            status: integer() | nil,
            retry_after_ms: non_neg_integer() | nil
          }
    defstruct [:kind, :message, status: nil, retry_after_ms: nil]
  end

  @type config :: term()
  @type delta :: String.t() | {:public_content, Elara.Provider.Visibility.public_part()}
  @type delta_sink :: (delta() -> :ok)

  @callback chat(config(), Request.t()) ::
              {:ok, Elara.Message.Assistant.t(), config()}
              | {:error, Error.t(), config()}

  @doc """
  Streams binary answer deltas or typed cumulative public-part upserts, then
  returns the canonical assistant. Binary deltas concatenate to assistant.text;
  typed parts identify reasoning summaries, commentary, or final answers by
  output/part index and kind. Repeated typed upserts replace that part's text.
  Final public_content supersedes streamed parts. Private continuation state
  never belongs in a delta.
  """
  @callback stream(config(), Request.t(), delta_sink()) ::
              {:ok, Elara.Message.Assistant.t(), config()}
              | {:error, Error.t(), config()}

  @optional_callbacks stream: 3
end
