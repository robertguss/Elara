defmodule Harness.Event do
  @moduledoc false

  @type turn_outcome ::
          {:completed, String.t()}
          | :turn_limit
          | :interrupted
          | {:provider_error, Harness.Provider.Error.t()}

  @type t ::
          {:turn_started, String.t()}
          | {:message_appended, Harness.Message.t()}
          | {:tool_started, Harness.Message.ToolCall.t()}
          | {:turn_ended, turn_outcome()}
end
