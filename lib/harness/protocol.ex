defmodule Harness.Protocol do
  @moduledoc "Versioned JSON command/event protocol shared by local gateways and clients."

  alias Harness.Message.{Assistant, ToolCall, ToolResult, User}
  alias Harness.Provider

  @version 1

  @spec version() :: pos_integer()
  def version, do: @version

  @spec encode(map()) :: iodata()
  def encode(message) when is_map(message), do: [JSON.encode!(message), "\n"]

  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(line) when is_binary(line) do
    case JSON.decode(line) do
      {:ok, %{} = message} -> {:ok, message}
      {:ok, _} -> {:error, :invalid_message}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec event(non_neg_integer(), Harness.Event.t()) :: map()
  def event(seq, event) do
    %{"type" => "event", "version" => @version, "seq" => seq, "event" => encode_event(event)}
  end

  @spec decode_event(map()) :: {:ok, Harness.Event.t()} | {:error, :invalid_event}
  def decode_event(%{"kind" => "turn_started", "prompt" => prompt}) when is_binary(prompt),
    do: {:ok, {:turn_started, prompt}}

  def decode_event(%{"kind" => "tool_started", "call" => call}) do
    with {:ok, call} <- decode_call(call), do: {:ok, {:tool_started, call}}
  end

  def decode_event(%{"kind" => "message_appended", "message" => message}) do
    with {:ok, message} <- decode_message(message), do: {:ok, {:message_appended, message}}
  end

  def decode_event(%{"kind" => "turn_ended", "outcome" => outcome}) do
    with {:ok, outcome} <- decode_turn_outcome(outcome), do: {:ok, {:turn_ended, outcome}}
  end

  def decode_event(_event), do: {:error, :invalid_event}

  defp encode_event({:turn_started, prompt}), do: %{"kind" => "turn_started", "prompt" => prompt}

  defp encode_event({:tool_started, call}),
    do: %{"kind" => "tool_started", "call" => encode_call(call)}

  defp encode_event({:message_appended, message}),
    do: %{"kind" => "message_appended", "message" => encode_message(message)}

  defp encode_event({:turn_ended, outcome}),
    do: %{"kind" => "turn_ended", "outcome" => encode_turn_outcome(outcome)}

  defp encode_message(%User{text: text}), do: %{"role" => "user", "text" => text}

  defp encode_message(%Assistant{text: text, tool_calls: calls}) do
    %{"role" => "assistant", "text" => text, "tool_calls" => Enum.map(calls, &encode_call/1)}
  end

  defp encode_message(%ToolResult{call_id: id, name: name, outcome: outcome}) do
    %{
      "role" => "tool",
      "call_id" => id,
      "name" => name,
      "outcome" => encode_tool_outcome(outcome)
    }
  end

  defp decode_message(%{"role" => "user", "text" => text}) when is_binary(text),
    do: {:ok, %User{text: text}}

  defp decode_message(%{"role" => "assistant", "text" => text, "tool_calls" => calls})
       when (is_binary(text) or is_nil(text)) and is_list(calls) do
    with {:ok, calls} <- map_ok(calls, &decode_call/1) do
      {:ok, %Assistant{text: text, tool_calls: calls}}
    end
  end

  defp decode_message(%{
         "role" => "tool",
         "call_id" => id,
         "name" => name,
         "outcome" => outcome
       })
       when is_binary(id) and is_binary(name) do
    with {:ok, outcome} <- decode_tool_outcome(outcome) do
      {:ok, %ToolResult{call_id: id, name: name, outcome: outcome}}
    end
  end

  defp decode_message(_message), do: {:error, :invalid_event}

  defp encode_call(%ToolCall{id: id, name: name, args: args}) do
    %{"id" => id, "name" => name, "args" => encode_args(args)}
  end

  defp decode_call(%{"id" => id, "name" => name, "args" => args})
       when is_binary(id) and is_binary(name) do
    with {:ok, args} <- decode_args(args), do: {:ok, %ToolCall{id: id, name: name, args: args}}
  end

  defp decode_call(_call), do: {:error, :invalid_event}

  defp encode_args({:ok, args}), do: %{"ok" => args}
  defp encode_args({:malformed, raw}), do: %{"malformed" => raw}
  defp decode_args(%{"ok" => args}) when is_map(args), do: {:ok, {:ok, args}}
  defp decode_args(%{"malformed" => raw}) when is_binary(raw), do: {:ok, {:malformed, raw}}
  defp decode_args(_args), do: {:error, :invalid_event}

  defp encode_tool_outcome({kind, text}) when kind in [:ok, :error],
    do: %{Atom.to_string(kind) => text}

  defp decode_tool_outcome(%{"ok" => text}) when is_binary(text), do: {:ok, {:ok, text}}
  defp decode_tool_outcome(%{"error" => text}) when is_binary(text), do: {:ok, {:error, text}}
  defp decode_tool_outcome(_outcome), do: {:error, :invalid_event}

  defp encode_turn_outcome({:completed, text}), do: %{"kind" => "completed", "text" => text}
  defp encode_turn_outcome(:turn_limit), do: %{"kind" => "turn_limit"}
  defp encode_turn_outcome(:interrupted), do: %{"kind" => "interrupted"}

  defp encode_turn_outcome({:provider_error, %Provider.Error{} = error}) do
    %{
      "kind" => "provider_error",
      "error" => %{"kind" => Atom.to_string(error.kind), "message" => error.message}
    }
  end

  defp decode_turn_outcome(%{"kind" => "completed", "text" => text}) when is_binary(text),
    do: {:ok, {:completed, text}}

  defp decode_turn_outcome(%{"kind" => "turn_limit"}), do: {:ok, :turn_limit}
  defp decode_turn_outcome(%{"kind" => "interrupted"}), do: {:ok, :interrupted}

  defp decode_turn_outcome(%{
         "kind" => "provider_error",
         "error" => %{"kind" => kind, "message" => message}
       })
       when is_binary(kind) and is_binary(message) do
    {:ok,
     {:provider_error, %Provider.Error{kind: String.to_existing_atom(kind), message: message}}}
  rescue
    ArgumentError -> {:error, :invalid_event}
  end

  defp decode_turn_outcome(_outcome), do: {:error, :invalid_event}

  defp map_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
