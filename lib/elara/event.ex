defmodule Elara.Event do
  @moduledoc false

  @type turn_outcome ::
          {:completed, String.t()}
          | :turn_limit
          | :interrupted
          | {:provider_error, Elara.Provider.Error.t()}

  @typedoc "A transient provider failure that will be retried after `delay_ms` at most."
  @type provider_retry :: %{
          attempt: pos_integer(),
          max_attempts: pos_integer(),
          delay_ms: non_neg_integer(),
          error: Elara.Provider.Error.t()
        }

  @type t ::
          :provider_view_changed
          | {:turn_started, String.t()}
          | {:provider_retry, provider_retry()}
          | {:message_appended, Elara.Message.t()}
          | {:message_appended, Elara.Message.Assistant.t(), :streamed}
          | {:content_delta, String.t(), String.t()}
          | {:tool_started, Elara.Message.ToolCall.t()}
          | {:turn_ended, turn_outcome()}
          | {:turn_ended, turn_outcome(), :streamed}
end
