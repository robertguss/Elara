defmodule Elara.Event do
  @moduledoc false

  @type turn_outcome ::
          {:completed, String.t()}
          | :turn_limit
          | :interrupted
          | {:provider_error, Elara.Provider.Error.t()}

  @type t ::
          :provider_view_changed
          | {:turn_started, String.t()}
          | {:message_appended, Elara.Message.t()}
          | {:message_appended, Elara.Message.Assistant.t(), :streamed}
          | {:content_delta, String.t(), String.t()}
          | {:tool_started, Elara.Message.ToolCall.t()}
          | {:turn_ended, turn_outcome()}
          | {:turn_ended, turn_outcome(), :streamed}
end
