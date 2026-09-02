defmodule Elara.Protocol do
  @moduledoc "Versioned JSON command/event protocol shared by local gateways and clients."

  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
  alias Elara.Provider
  alias Elara.Session.Core

  @version 2
  @versions [1, 2]
  @max_line_bytes 16 * 1_024 * 1_024

  @spec version() :: pos_integer()
  def version, do: @version

  @spec versions() :: [pos_integer()]
  def versions, do: @versions

  @spec v1() :: 1
  def v1, do: 1

  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @spec line_buffer() :: {iodata(), non_neg_integer()}
  def line_buffer, do: {[], 0}

  @spec push_line({iodata(), non_neg_integer()}, binary()) ::
          {:ok, binary()} | {:more, {iodata(), non_neg_integer()}} | {:error, :message_too_large}
  def push_line({parts, size}, chunk) when is_binary(chunk) do
    size = size + byte_size(chunk)

    cond do
      size > @max_line_bytes ->
        {:error, :message_too_large}

      chunk != "" and :binary.last(chunk) == ?\n ->
        {:ok, parts |> Enum.reverse([chunk]) |> IO.iodata_to_binary()}

      true ->
        {:more, {[chunk | parts], size}}
    end
  end

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

  @spec event(non_neg_integer(), Elara.Event.t()) :: map()
  def event(seq, event) do
    %{"type" => "event", "version" => 1, "seq" => seq, "event" => encode_event(event)}
  end

  @spec snapshot(String.t(), String.t(), Core.State.t()) :: map()
  def snapshot(session_id, incarnation, %Core.State{} = core) do
    %{
      "session" => %{"id" => session_id, "incarnation" => incarnation},
      "messages" => Enum.map(core.history, &encode_message/1),
      "tool_calls" => tool_views(core),
      "turn" => encode_phase(core.phase),
      "usage" => nil,
      "content_deltas" => content_deltas(core)
    }
  end

  @spec patch(non_neg_integer(), [map()]) :: map()
  def patch(seq, ops) when is_integer(seq) and seq >= 0 and is_list(ops) do
    %{"type" => "patch", "version" => 2, "seq" => seq, "ops" => ops}
  end

  @spec patch_ops(
          Elara.Event.t(),
          Core.State.t(),
          {non_neg_integer(), [Elara.Message.t()]}
          | %{
              message_offset: non_neg_integer(),
              messages: [Elara.Message.t()],
              supersedes: String.t() | nil
            }
        ) :: [map()]
  def patch_ops(event, %Core.State{} = core, {message_offset, messages}) do
    patch_ops(event, core, %{
      message_offset: message_offset,
      messages: messages,
      supersedes: nil
    })
  end

  def patch_ops(event, %Core.State{} = core, %{
        message_offset: message_offset,
        messages: messages,
        supersedes: supersedes
      }) do
    reconcile_messages(message_offset, messages, supersedes) ++
      reconcile_tool_statuses(messages, core) ++
      event_ops(event, message_offset, messages, supersedes) ++
      [
        maybe_supersedes(
          %{"op" => "set_turn_state", "turn" => event_turn(event, core.phase)},
          supersedes
        )
      ]
  end

  @spec apply_patch(map(), [map()]) :: {:ok, map()} | {:error, :invalid_patch}
  def apply_patch(view, ops) when is_map(view) and is_list(ops) do
    Enum.reduce_while(ops, {:ok, view}, fn op, {:ok, view} ->
      case apply_op(view, op) do
        {:ok, view} -> {:cont, {:ok, view}}
        {:error, :invalid_patch} = error -> {:halt, error}
      end
    end)
  end

  def apply_patch(_view, _ops), do: {:error, :invalid_patch}

  @spec decode_event(map()) :: {:ok, Elara.Event.t()} | {:error, :invalid_event}
  def decode_event(%{"kind" => "turn_started", "prompt" => prompt}) when is_binary(prompt),
    do: {:ok, {:turn_started, prompt}}

  def decode_event(%{"kind" => "tool_started", "call" => call}) do
    with {:ok, call} <- decode_call(call), do: {:ok, {:tool_started, call}}
  end

  def decode_event(%{
        "kind" => "message_appended",
        "message" => message,
        "streamed" => true
      }) do
    with {:ok, %Assistant{} = message} <- decode_message(message) do
      {:ok, {:message_appended, message, :streamed}}
    else
      _error -> {:error, :invalid_event}
    end
  end

  def decode_event(%{"kind" => "message_appended", "message" => message}) do
    with {:ok, message} <- decode_message(message), do: {:ok, {:message_appended, message}}
  end

  def decode_event(%{
        "kind" => "content_delta",
        "message_id" => id,
        "text" => text
      })
      when is_binary(id) and is_binary(text),
      do: {:ok, {:content_delta, id, text}}

  def decode_event(%{"kind" => "turn_ended", "outcome" => outcome, "streamed" => true}) do
    with {:ok, outcome} <- decode_turn_outcome(outcome) do
      {:ok, {:turn_ended, outcome, :streamed}}
    end
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

  defp encode_event({:message_appended, %Assistant{} = message, :streamed}) do
    %{"kind" => "message_appended", "message" => encode_message(message), "streamed" => true}
  end

  defp encode_event({:content_delta, id, text}),
    do: %{"kind" => "content_delta", "message_id" => id, "text" => text}

  defp encode_event({:turn_ended, outcome, :streamed}) do
    %{"kind" => "turn_ended", "outcome" => encode_turn_outcome(outcome), "streamed" => true}
  end

  defp encode_event({:turn_ended, outcome}),
    do: %{"kind" => "turn_ended", "outcome" => encode_turn_outcome(outcome)}

  defp reconcile_messages(offset, messages, supersedes) do
    messages
    |> Enum.with_index(offset)
    |> Enum.map(fn {message, index} ->
      maybe_supersedes(
        %{
          "op" => "append_message",
          "index" => index,
          "message" => encode_message(message)
        },
        supersedes
      )
    end)
  end

  defp reconcile_tool_statuses(messages, core) do
    running_id =
      case core.phase do
        {:running_tool, _ref, call, _remaining, _iteration} -> call.id
        _phase -> nil
      end

    ids =
      messages
      |> Enum.flat_map(fn
        %Assistant{tool_calls: calls} -> Enum.map(calls, & &1.id)
        %ToolResult{call_id: id} -> [id]
        _message -> []
      end)
      |> then(&if(running_id, do: [running_id | &1], else: &1))
      |> Enum.uniq()

    views = Map.new(tool_views(core), &{&1["id"], &1})

    Enum.flat_map(ids, fn id ->
      case Map.fetch(views, id) do
        {:ok, view} ->
          [
            %{
              "op" => "set_tool_status",
              "id" => id,
              "status" => view["status"],
              "outcome" => view["outcome"]
            }
          ]

        :error ->
          []
      end
    end)
  end

  defp event_ops({:turn_started, _prompt}, _offset, _messages, _supersedes), do: []

  defp event_ops({:tool_started, call}, _offset, _messages, _supersedes) do
    [
      %{
        "op" => "set_tool_status",
        "id" => call.id,
        "status" => "running",
        "outcome" => nil,
        "call" => encode_call(call)
      }
    ]
  end

  defp event_ops({:message_appended, message}, offset, messages, supersedes) do
    message_op(message, offset, messages, supersedes, false)
  end

  defp event_ops(
         {:message_appended, %Assistant{} = message, :streamed},
         offset,
         messages,
         supersedes
       ) do
    message_op(message, offset, messages, supersedes, true)
  end

  defp event_ops({:content_delta, id, text}, _offset, _messages, _supersedes) do
    [%{"op" => "append_content_delta", "message_id" => id, "text" => text}]
  end

  defp event_ops({:turn_ended, _outcome, :streamed}, _offset, _messages, _supersedes),
    do: []

  defp event_ops({:turn_ended, _outcome}, _offset, _messages, _supersedes), do: []

  defp message_op(message, offset, messages, supersedes, streamed?) do
    index =
      case Enum.find_index(messages, &(&1 == message)) do
        nil -> raise ArgumentError, "emitted message is absent from its Core transition"
        index -> offset + index
      end

    [
      maybe_supersedes(
        %{
          "op" => "append_message",
          "index" => index,
          "message" => encode_message(message),
          "render" => true,
          "streamed" => streamed?
        },
        supersedes
      )
    ]
  end

  defp event_turn({:turn_started, prompt}, phase),
    do: Map.put(encode_phase(phase), "prompt", prompt)

  defp event_turn({:turn_ended, outcome}, phase),
    do: Map.put(encode_phase(phase), "outcome", encode_turn_outcome(outcome))

  defp event_turn({:turn_ended, outcome, :streamed}, phase) do
    phase
    |> encode_phase()
    |> Map.put("outcome", encode_turn_outcome(outcome))
    |> Map.put("streamed", true)
  end

  defp event_turn(_event, phase), do: encode_phase(phase)

  defp encode_phase(:idle), do: %{"state" => "idle"}

  defp encode_phase({:calling_provider, _ref, iteration}),
    do: %{"state" => "calling_provider", "iteration" => iteration}

  defp encode_phase({:running_tool, _ref, call, _remaining, iteration}) do
    %{"state" => "running_tool", "tool_call_id" => call.id, "iteration" => iteration}
  end

  defp tool_views(%Core.State{} = core) do
    results =
      core.history
      |> Enum.filter(&is_struct(&1, ToolResult))
      |> Map.new(&{&1.call_id, &1.outcome})

    running =
      case core.phase do
        {:running_tool, _ref, call, _remaining, _iteration} -> call.id
        _phase -> nil
      end

    core.history
    |> Enum.filter(&is_struct(&1, Assistant))
    |> Enum.flat_map(& &1.tool_calls)
    |> Enum.map(fn call ->
      case Map.fetch(results, call.id) do
        {:ok, outcome} ->
          call
          |> encode_call()
          |> Map.merge(%{
            "status" => tool_status(outcome),
            "outcome" => encode_tool_outcome(outcome)
          })

        :error when call.id == running ->
          call |> encode_call() |> Map.merge(%{"status" => "running", "outcome" => nil})

        :error ->
          call |> encode_call() |> Map.merge(%{"status" => "pending", "outcome" => nil})
      end
    end)
  end

  defp tool_status({:ok, _text}), do: "succeeded"
  defp tool_status({:error, _text}), do: "failed"
  defp tool_status({:indeterminate, _text}), do: "indeterminate"

  defp content_deltas(%Core.State{streaming: %{id: id, text: text}}) when text != "",
    do: %{id => text}

  defp content_deltas(%Core.State{}), do: %{}

  defp maybe_supersedes(op, nil), do: op
  defp maybe_supersedes(op, id) when is_binary(id), do: Map.put(op, "supersedes", id)

  defp apply_op(
         %{"messages" => messages, "tool_calls" => tool_calls} = view,
         %{"op" => "append_message", "index" => index, "message" => message} = op
       )
       when is_list(messages) and is_list(tool_calls) and is_integer(index) and index >= 0 and
              is_map(message) do
    result =
      cond do
        index < length(messages) and Enum.at(messages, index) == message ->
          {:ok, view}

        index == length(messages) ->
          append_message(view, messages, tool_calls, message)

        true ->
          {:error, :invalid_patch}
      end

    with {:ok, view} <- result do
      clear_superseded(view, Map.get(op, "supersedes"))
    end
  end

  defp apply_op(
         %{"tool_calls" => calls} = view,
         %{"op" => "set_tool_status", "id" => id, "status" => status, "outcome" => outcome}
       )
       when is_list(calls) and is_binary(id) and
              status in ["pending", "running", "succeeded", "failed", "indeterminate"] do
    if Enum.any?(calls, &(&1["id"] == id)) do
      calls =
        Enum.map(calls, fn
          %{"id" => ^id} = call -> Map.merge(call, %{"status" => status, "outcome" => outcome})
          call -> call
        end)

      {:ok, %{view | "tool_calls" => calls}}
    else
      {:error, :invalid_patch}
    end
  end

  defp apply_op(view, %{"op" => "set_turn_state", "turn" => %{"state" => state} = turn} = op)
       when state in ["idle", "calling_provider", "running_tool"] do
    view = Map.put(view, "turn", Map.drop(turn, ["prompt", "outcome", "streamed"]))
    clear_superseded(view, Map.get(op, "supersedes"))
  end

  defp apply_op(view, %{"op" => "set_usage", "usage" => usage})
       when is_map(usage) or is_nil(usage),
       do: {:ok, Map.put(view, "usage", usage)}

  defp apply_op(
         %{"content_deltas" => deltas} = view,
         %{"op" => "append_content_delta", "message_id" => id, "text" => text}
       )
       when is_map(deltas) and is_binary(id) and is_binary(text) do
    {:ok, %{view | "content_deltas" => Map.update(deltas, id, text, &(&1 <> text))}}
  end

  defp apply_op(_view, _op), do: {:error, :invalid_patch}

  defp clear_superseded(view, nil), do: {:ok, view}

  defp clear_superseded(%{"content_deltas" => deltas} = view, id)
       when is_map(deltas) and is_binary(id) do
    {:ok, %{view | "content_deltas" => Map.delete(deltas, id)}}
  end

  defp clear_superseded(_view, _id), do: {:error, :invalid_patch}

  defp append_message(view, messages, tool_calls, message) do
    case decode_message(message) do
      {:ok, %Assistant{tool_calls: calls}} ->
        new_calls =
          Enum.map(calls, fn call ->
            call |> encode_call() |> Map.merge(%{"status" => "pending", "outcome" => nil})
          end)

        {:ok,
         %{view | "messages" => messages ++ [message], "tool_calls" => tool_calls ++ new_calls}}

      {:ok, _message} ->
        {:ok, %{view | "messages" => messages ++ [message]}}

      {:error, _reason} ->
        {:error, :invalid_patch}
    end
  end

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

  defp encode_tool_outcome({kind, text}) when kind in [:ok, :error, :indeterminate],
    do: %{Atom.to_string(kind) => text}

  defp decode_tool_outcome(%{"ok" => text}) when is_binary(text), do: {:ok, {:ok, text}}
  defp decode_tool_outcome(%{"error" => text}) when is_binary(text), do: {:ok, {:error, text}}

  defp decode_tool_outcome(%{"indeterminate" => text}) when is_binary(text),
    do: {:ok, {:indeterminate, text}}

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
