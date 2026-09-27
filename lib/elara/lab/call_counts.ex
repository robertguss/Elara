defmodule Elara.Lab.CallCounts do
  @moduledoc """
  Installs call-count patterns in a lab trace session. Loads each module first
  and refuses a pattern that matched other than one function; reads and judges
  no counts.
  """

  @doc """
  Count calls to `{m, f, a}` in `session`. Raises when `m` cannot be loaded or
  the pattern matched other than exactly one function, so an untraced function
  is never reported as zero calls.
  """
  @spec install!(:trace.session(), mfa()) :: :ok
  def install!(session, {m, f, a} = mfa) do
    Code.ensure_loaded!(m)

    case :trace.function(session, mfa, true, [:call_count]) do
      1 ->
        :ok

      n ->
        raise ArgumentError,
              "call-count pattern for #{Exception.format_mfa(m, f, a)} matched #{n} functions"
    end
  end
end
