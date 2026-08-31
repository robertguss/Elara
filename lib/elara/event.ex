defmodule Elara.Event do
  @moduledoc false

  @type turn_outcome ::
          {:completed, String.t()}
          | :turn_limit
          | :interrupted
          | {:provider_error, Elara.Provider.Error.t()}

  @type t ::
          {:turn_started, String.t()}
          | {:message_appended, Elara.Message.t()}
          | {:tool_started, Elara.Message.ToolCall.t()}
          | {:turn_ended, turn_outcome()}
end
