defmodule Elara.Message do
  @moduledoc """
  History is a list of these three structs, oldest first. Nothing else.
  """

  defmodule ToolCall do
    @type args :: {:ok, map()} | {:malformed, String.t()}
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            args: args(),
            output_index: non_neg_integer() | nil
          }
    defstruct [:id, :name, :args, :output_index]
  end

  defmodule User do
    @type t :: %__MODULE__{text: String.t(), attachments: [map()]}
    @derive {Inspect, except: [:attachments]}
    defstruct text: nil, attachments: [], agent_source: nil
  end

  defmodule Assistant do
    @typedoc "Completed messages have text or calls; interrupted messages may contain only public parts."
    @type t :: %__MODULE__{
            text: String.t() | nil,
            tool_calls: [ToolCall.t()],
            provider_state: map() | nil,
            public_content: [Elara.Provider.Visibility.public_part()],
            usage: Elara.Provider.Visibility.usage() | nil,
            response_model: String.t() | nil,
            request_settings: Elara.Provider.Visibility.settings() | nil,
            interrupted: boolean()
          }
    @derive {Inspect, except: [:provider_state]}
    defstruct text: nil,
              tool_calls: [],
              provider_state: nil,
              public_content: [],
              usage: nil,
              response_model: nil,
              request_settings: nil,
              interrupted: false
  end

  defmodule ToolResult do
    @type t :: %__MODULE__{call_id: String.t(), name: String.t(), outcome: Elara.Tool.outcome()}
    defstruct [:call_id, :name, :outcome]
  end

  @type t :: User.t() | Assistant.t() | ToolResult.t()

  @doc "Build a completed text/tool assistant. Public-only interrupted messages are built by Core."
  @spec assistant(String.t() | nil, [ToolCall.t()], map() | nil) ::
          {:ok, Assistant.t()} | {:error, :empty_assistant}
  def assistant(text, tool_calls, provider_state \\ nil)
      when (is_binary(text) or is_nil(text)) and is_list(tool_calls) and
             (is_map(provider_state) or is_nil(provider_state)) do
    text_empty? = text == nil or text == ""
    calls_empty? = tool_calls == []

    if text_empty? and calls_empty? do
      {:error, :empty_assistant}
    else
      {:ok, %Assistant{text: text, tool_calls: tool_calls, provider_state: provider_state}}
    end
  end

  @spec user(String.t()) :: User.t()
  def user(text) when is_binary(text), do: %User{text: text}

  @spec tool_result(ToolCall.t(), Elara.Tool.outcome()) :: ToolResult.t()
  def tool_result(%ToolCall{} = call, outcome) do
    %ToolResult{call_id: call.id, name: call.name, outcome: outcome}
  end
end
