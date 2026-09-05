defmodule Elara.Provider.OpenAICodex do
  @moduledoc "ChatGPT subscription-backed Codex Responses adapter."

  @behaviour Elara.Provider

  alias Elara.Auth.OpenAICodex, as: Auth
  alias Elara.Message
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
  alias Elara.Provider
  alias Elara.Provider.Error
  alias Elara.Tool

  @default_base_url "https://chatgpt.com/backend-api"
  @default_model "gpt-5.5"

  @spec default_model() :: String.t()
  def default_model, do: @default_model
  @provider_state_key "openai_codex"

  @derive {Inspect, except: [:tokens]}
  defstruct [:tokens, :model, :base_url, :originator, effort: "low"]

  @type config :: %__MODULE__{
          tokens: Auth.t(),
          model: String.t(),
          effort: String.t(),
          base_url: String.t(),
          originator: String.t()
        }

  @spec new(Auth.t(), keyword()) :: config()
  def new(%Auth{} = tokens, opts \\ []) do
    %__MODULE__{
      tokens: tokens,
      model: Keyword.get(opts, :model, @default_model),
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      originator: Keyword.get(opts, :originator, "elara"),
      effort: Keyword.get(opts, :effort, "low")
    }
  end

  @impl true
  def chat(%__MODULE__{} = config, %Provider.Request{} = request) do
    stream(config, request, fn _text -> :ok end)
  end

  @impl true
  def stream(%__MODULE__{} = config, %Provider.Request{} = request, sink)
      when is_function(sink, 1) do
    case Auth.refresh_if_needed(config.tokens) do
      {:ok, tokens} ->
        config = %{config | tokens: tokens}
        do_stream(config, request, sink)

      {:error, reason} ->
        {:error,
         %Error{
           kind: :transport,
           message: "OpenAI token refresh failed: #{Elara.Config.error_message(reason)}"
         }, config}
    end
  end

  @doc false
  @spec build_body(config(), Provider.Request.t()) :: map()
  def build_body(%__MODULE__{} = config, %Provider.Request{} = request) do
    body = %{
      "model" => config.model,
      "reasoning" => %{"effort" => config.effort, "summary" => "auto"},
      "store" => false,
      "stream" => true,
      "instructions" => request.system,
      "input" => Enum.flat_map(request.messages, &encode_message/1),
      "text" => %{"verbosity" => "low"},
      "include" => ["reasoning.encrypted_content"],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true
    }

    case request.tools do
      [] -> body
      tools -> Map.put(body, "tools", Enum.map(tools, &encode_tool/1))
    end
  end

  @doc false
  @spec parse_stream_chunks([binary()], Provider.delta_sink()) ::
          {:ok, Assistant.t()} | {:error, Error.t()}
  def parse_stream_chunks(chunks, sink) when is_list(chunks) and is_function(sink, 1) do
    result =
      Enum.reduce_while(chunks, {:ok, new_stream_state()}, fn chunk, {:ok, state} ->
        case consume_stream_data(state, chunk, sink) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, error, state} -> {:halt, {:error, error, state}}
        end
      end)

    case result do
      {:ok, state} -> finish_stream({:ok, %Req.Response{status: 200}}, state)
      {:error, error, _state} -> {:error, error}
    end
  end

  defp do_stream(config, request, sink) do
    url = String.trim_trailing(config.base_url, "/") <> "/codex/responses"
    state_key = {__MODULE__, :stream, make_ref()}
    Process.put(state_key, new_stream_state())

    into = fn {:data, data}, {req, response} ->
      state = Process.get(state_key)

      result =
        if response.status == 200 do
          consume_stream_data(state, data, sink)
        else
          {:ok, %{state | error_body: capped_body(state.error_body, data)}}
        end

      case result do
        {:ok, state} ->
          Process.put(state_key, state)
          {:cont, {req, response}}

        {:error, %Error{} = error, state} ->
          Process.put(state_key, %{state | error: error})
          {:halt, {req, response}}
      end
    end

    {result, state} =
      try do
        result =
          Req.post(url,
            headers: request_headers(config),
            json: build_body(config, request),
            decode_body: false,
            receive_timeout: 120_000,
            retry: false,
            into: into
          )

        {result, Process.get(state_key)}
      after
        Process.delete(state_key)
      end

    case finish_stream(result, state) do
      {:ok, assistant} -> {:ok, assistant, config}
      {:error, error} -> {:error, classify_error(error), config}
    end
  end

  defp request_headers(config) do
    [
      {"authorization", "Bearer #{config.tokens.access_token}"},
      {"chatgpt-account-id", config.tokens.account_id},
      {"originator", config.originator},
      {"user-agent", "elara/#{Application.spec(:elara, :vsn)}"},
      {"openai-beta", "responses=experimental"},
      {"accept", "text/event-stream"},
      {"content-type", "application/json"}
    ]
  end

  defp encode_message(%User{} = user) do
    images =
      for %{"kind" => "image", "mime_type" => mime, "base64" => data} <- user.attachments,
          do: %{"type" => "input_image", "image_url" => "data:#{mime};base64,#{data}"}

    [
      %{
        "role" => "user",
        "content" =>
          [%{"type" => "input_text", "text" => Elara.Attachment.provider_text(user)}] ++ images
      }
    ]
  end

  defp encode_message(%Assistant{} = assistant) do
    case native_output(assistant) do
      {:ok, output} -> output
      :error -> encode_domain_assistant(assistant)
    end
  end

  defp encode_message(%ToolResult{call_id: id, outcome: outcome}) do
    [
      %{
        "type" => "function_call_output",
        "call_id" => native_call_id(id),
        "output" => encode_outcome(outcome)
      }
    ]
  end

  defp native_output(%Assistant{
         provider_state: %{@provider_state_key => %{"output" => output}}
       })
       when is_list(output) and output != [] do
    if Enum.all?(output, &is_map/1), do: {:ok, output}, else: :error
  end

  defp native_output(%Assistant{}), do: :error

  defp encode_domain_assistant(%Assistant{text: text, tool_calls: calls}) do
    text_items =
      if is_binary(text) and text != "" do
        [
          %{
            "type" => "message",
            "role" => "assistant",
            "status" => "completed",
            "content" => [
              %{"type" => "output_text", "text" => text, "annotations" => []}
            ]
          }
        ]
      else
        []
      end

    text_items ++ Enum.map(calls, &encode_domain_call/1)
  end

  defp encode_domain_call(%ToolCall{id: id, name: name, args: args}) do
    {call_id, item_id} = split_call_id(id)

    %{
      "type" => "function_call",
      "call_id" => call_id,
      "name" => name,
      "arguments" => encode_arguments(args)
    }
    |> put_optional("id", item_id)
  end

  defp encode_tool(%Tool{name: name, description: description, parameters: parameters}) do
    %{
      "type" => "function",
      "name" => name,
      "description" => description,
      "parameters" => parameters,
      "strict" => false
    }
  end

  defp encode_arguments({:ok, arguments}), do: JSON.encode!(arguments)
  defp encode_arguments({:malformed, raw}), do: raw

  defp encode_outcome({:ok, text}), do: text
  defp encode_outcome({:error, text}), do: "ERROR: " <> text
  defp encode_outcome({:indeterminate, text}), do: "INDETERMINATE: " <> text

  defp new_stream_state do
    %{
      buffer: "",
      text: "",
      public_content: [],
      items: %{},
      terminal: nil,
      error: nil,
      error_body: ""
    }
  end

  defp consume_stream_data(state, data, sink) when is_binary(data) do
    normalized =
      (state.buffer <> data)
      |> :binary.replace("\r\n", "\n", [:global])

    parts = :binary.split(normalized, "\n\n", [:global])
    buffer = List.last(parts)
    frames = Enum.drop(parts, -1)
    state = %{state | buffer: buffer}

    Enum.reduce_while(frames, {:ok, state}, fn frame, {:ok, state} ->
      case consume_stream_frame(state, frame, sink) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error, state} -> {:halt, {:error, error, state}}
      end
    end)
  end

  defp consume_stream_frame(state, frame, sink) do
    data =
      frame
      |> :binary.split("\n", [:global])
      |> Enum.flat_map(fn
        "data:" <> data -> [strip_sse_space(data)]
        _other_line -> []
      end)
      |> Enum.join("\n")

    cond do
      data in ["", "[DONE]"] ->
        {:ok, state}

      true ->
        case JSON.decode(data) do
          {:ok, %{} = event} -> consume_event(state, event, sink)
          _ -> stream_error(state, "invalid SSE JSON")
        end
    end
  end

  defp consume_event(
         state,
         %{
           "type" => type,
           "output_index" => index,
           "item" => item
         },
         _sink
       )
       when type in ["response.output_item.added", "response.output_item.done"] and
              is_integer(index) and index >= 0 and is_map(item) do
    {:ok, put_item(state, index, item)}
  end

  defp consume_event(
         state,
         %{"type" => "response.reasoning_summary_text.done", "text" => text} = event,
         sink
       )
       when is_binary(text) do
    index = Map.get(event, "output_index", 0)
    item = Map.get(state.items, index, %{})

    part = %{
      "kind" => "reasoning_summary",
      "item_id" => Map.get(event, "item_id", item["id"] || "output-#{index}"),
      "output_index" => index,
      "part_index" => Map.get(event, "summary_index", 0),
      "text" => text
    }

    :ok = sink.({:public_content, part})
    {:ok, %{state | public_content: Elara.Provider.Visibility.upsert(state.public_content, part)}}
  end

  defp consume_event(
         state,
         %{"type" => "response.reasoning_summary_text.delta", "delta" => delta} = event,
         sink
       )
       when is_binary(delta) do
    public_delta(
      state,
      event,
      "reasoning_summary",
      Map.get(event, "summary_index", 0),
      delta,
      sink
    )
  end

  defp consume_event(
         state,
         %{
           "type" => "response.output_text.delta",
           "delta" => delta
         } = event,
         sink
       )
       when is_binary(delta) do
    item = Map.get(state.items, Map.get(event, "output_index", 0), %{})
    kind = if item["phase"] == "commentary", do: "commentary", else: "final_answer"

    {:ok, state} =
      public_delta(state, event, kind, Map.get(event, "content_index", 0), delta, sink)

    if kind == "final_answer", do: :ok = sink.(delta)
    {:ok, %{state | text: state.text <> if(kind == "final_answer", do: delta, else: "")}}
  end

  defp consume_event(
         state,
         %{
           "type" => "response.function_call_arguments.delta",
           "output_index" => index,
           "delta" => delta
         },
         _sink
       )
       when is_integer(index) and index >= 0 and is_binary(delta) do
    {:ok, update_call_arguments(state, index, &(&1 <> delta))}
  end

  defp consume_event(
         state,
         %{
           "type" => "response.function_call_arguments.done",
           "output_index" => index,
           "arguments" => arguments
         },
         _sink
       )
       when is_integer(index) and index >= 0 and is_binary(arguments) do
    {:ok, update_call_arguments(state, index, fn _current -> arguments end)}
  end

  defp consume_event(state, %{"type" => "response.completed", "response" => response}, _sink)
       when is_map(response) do
    {:ok, %{state | terminal: {:completed, response}}}
  end

  defp consume_event(state, %{"type" => "response.incomplete", "response" => response}, _sink)
       when is_map(response) do
    reason = get_in(response, ["incomplete_details", "reason"]) || "unknown reason"
    stream_error(state, "response incomplete: #{reason}")
  end

  defp consume_event(state, %{"type" => "response.failed", "response" => response}, _sink)
       when is_map(response) do
    message = get_in(response, ["error", "message"]) || "response failed"
    stream_error(state, message)
  end

  defp consume_event(state, %{"type" => "error"} = event, _sink) do
    message = get_in(event, ["error", "message"]) || Map.get(event, "message") || "stream error"
    stream_error(state, message)
  end

  defp consume_event(state, %{"type" => type}, _sink)
       when type in [
              "response.created",
              "response.in_progress",
              "response.content_part.added",
              "response.content_part.done",
              "response.reasoning_summary_part.added",
              "response.reasoning_summary_part.done",
              "response.reasoning_summary_text.delta",
              "response.reasoning_summary_text.done",
              "response.reasoning_text.delta",
              "response.reasoning_text.done"
            ],
       do: {:ok, state}

  defp consume_event(state, %{"type" => _unknown}, _sink), do: {:ok, state}
  defp consume_event(state, _event, _sink), do: stream_error(state, "SSE event missing type")

  defp put_item(state, index, item), do: %{state | items: Map.put(state.items, index, item)}

  defp update_call_arguments(state, index, update) do
    case Map.get(state.items, index) do
      %{"type" => "function_call"} = item ->
        current = Map.get(item, "arguments", "")
        put_item(state, index, Map.put(item, "arguments", update.(current)))

      _ ->
        state
    end
  end

  defp finish_stream({:error, exception}, _state) do
    {:error, %Error{kind: :transport, message: Exception.message(exception)}}
  end

  defp finish_stream({:ok, %Req.Response{status: status}}, state) when status != 200 do
    {:error, %Error{kind: :http, status: status, message: "HTTP #{status}: #{state.error_body}"}}
  end

  defp finish_stream({:ok, %Req.Response{status: 200}}, %{error: %Error{} = error}),
    do: {:error, error}

  defp finish_stream({:ok, %Req.Response{status: 200}}, %{terminal: nil} = state) do
    if blank_stream_buffer?(state.buffer) do
      {:error, %Error{kind: :bad_response, message: "stream ended before a terminal response"}}
    else
      {:error, %Error{kind: :bad_response, message: "stream ended with an incomplete SSE frame"}}
    end
  end

  defp finish_stream(
         {:ok, %Req.Response{status: 200}},
         %{terminal: {:completed, response}} = state
       ) do
    if blank_stream_buffer?(state.buffer) do
      output = canonical_output(state, response)

      with {:ok, text} <- output_text(output),
           :ok <- verify_streamed_text(state.text, text),
           {:ok, calls} <- output_calls(output),
           provider_state = %{@provider_state_key => %{"output" => output}},
           {:ok, assistant} <- Message.assistant(empty_to_nil(text), calls, provider_state) do
        {:ok,
         %{
           assistant
           | public_content: public_output(output),
             usage: Elara.Provider.Visibility.usage(response["usage"]),
             response_model: response["model"]
         }}
      else
        {:error, %Error{} = error} ->
          {:error, error}

        {:error, :empty_assistant} ->
          {:error, %Error{kind: :bad_response, message: "empty assistant response"}}
      end
    else
      {:error, %Error{kind: :bad_response, message: "stream ended with an incomplete SSE frame"}}
    end
  end

  defp public_delta(state, event, kind, part_index, delta, sink) do
    index = Map.get(event, "output_index", 0)
    item = Map.get(state.items, index, %{})

    part = %{
      "kind" => kind,
      "item_id" => Map.get(event, "item_id", item["id"] || "output-#{index}"),
      "output_index" => index,
      "part_index" => part_index,
      "text" => delta
    }

    previous =
      Enum.find(
        state.public_content,
        &(Elara.Provider.Visibility.key(&1) == Elara.Provider.Visibility.key(part))
      )

    part = if previous, do: %{part | "text" => previous["text"] <> delta}, else: part
    :ok = sink.({:public_content, part})
    {:ok, %{state | public_content: Elara.Provider.Visibility.upsert(state.public_content, part)}}
  end

  defp public_output(output) do
    output
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      {kind, parts} =
        case item do
          %{"type" => "reasoning"} ->
            {"reasoning_summary", Map.get(item, "summary", [])}

          %{"type" => "message", "role" => "assistant"} ->
            {if(item["phase"] == "commentary", do: "commentary", else: "final_answer"),
             Map.get(item, "content", [])}

          _ ->
            {nil, []}
        end

      parts
      |> Enum.with_index()
      |> Enum.flat_map(fn {part, part_index} ->
        if part["type"] in ["summary_text", "output_text"] and is_binary(part["text"]) do
          [
            %{
              "kind" => kind,
              "item_id" => item["id"] || "output-#{index}",
              "output_index" => index,
              "part_index" => part_index,
              "text" => part["text"]
            }
          ]
        else
          []
        end
      end)
    end)
  end

  defp canonical_output(_state, %{"output" => output}) when is_list(output) and output != [],
    do: output

  defp canonical_output(state, _response) do
    state.items
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp output_text(output) do
    Enum.reduce_while(output, {:ok, ""}, fn
      %{"type" => "message", "phase" => "commentary"}, result ->
        {:cont, result}

      %{
        "type" => "message",
        "id" => id,
        "role" => "assistant",
        "content" => content
      },
      {:ok, text}
      when is_binary(id) and id != "" and is_list(content) ->
        case message_text(content) do
          {:ok, chunk} -> {:cont, {:ok, text <> chunk}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      %{"type" => "message"}, {:ok, _text} ->
        {:halt, bad_response("malformed assistant message")}

      _item, result ->
        {:cont, result}
    end)
  end

  defp message_text(content) do
    Enum.reduce_while(content, {:ok, ""}, fn
      %{"type" => "output_text", "text" => text}, {:ok, acc} when is_binary(text) ->
        {:cont, {:ok, acc <> text}}

      %{"type" => type}, {:ok, _acc} ->
        {:halt, bad_response("unsupported assistant content: #{inspect(type)}")}

      _part, {:ok, _acc} ->
        {:halt, bad_response("malformed assistant content")}
    end)
  end

  defp output_calls(output) do
    output
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{
         "type" => "function_call",
         "id" => item_id,
         "call_id" => call_id,
         "name" => name,
         "arguments" => arguments
       }, index},
      {:ok, calls}
      when is_binary(item_id) and item_id != "" and is_binary(call_id) and call_id != "" and
             is_binary(name) and name != "" and is_binary(arguments) ->
        call = %ToolCall{
          id: call_id <> "|" <> item_id,
          name: name,
          args: decode_arguments(arguments),
          output_index: index
        }

        {:cont, {:ok, [call | calls]}}

      {%{"type" => "function_call"}, _index}, {:ok, _calls} ->
        {:halt, bad_response("malformed function call")}

      _item, result ->
        {:cont, result}
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  defp decode_arguments(arguments) do
    case JSON.decode(arguments) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:malformed, arguments}
    end
  end

  defp verify_streamed_text("", _text), do: :ok
  defp verify_streamed_text(text, text), do: :ok

  defp verify_streamed_text(_streamed, _final),
    do: bad_response("final assistant did not match streamed content")

  defp classify_error(%Error{kind: :http, status: status} = error) when status in [401, 403] do
    %{
      error
      | kind: :entitlement,
        message: "#{error.message}. Run `mix elara.login openai` to sign in again."
    }
  end

  defp classify_error(%Error{} = error), do: error

  defp stream_error(state, message) do
    error = %Error{kind: :bad_response, message: message}
    {:error, error, %{state | error: error}}
  end

  defp bad_response(message), do: {:error, %Error{kind: :bad_response, message: message}}

  defp split_call_id(id) do
    case String.split(id, "|", parts: 2) do
      [call_id, item_id] when call_id != "" and item_id != "" -> {call_id, item_id}
      _ -> {id, nil}
    end
  end

  defp native_call_id(id), do: id |> split_call_id() |> elem(0)
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(text), do: text
  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp strip_sse_space(<<" ", rest::binary>>), do: rest
  defp strip_sse_space(data), do: data

  defp blank_stream_buffer?(<<>>), do: true

  defp blank_stream_buffer?(<<byte, rest::binary>>) when byte in [?\s, ?\t, ?\n],
    do: blank_stream_buffer?(rest)

  defp blank_stream_buffer?(_buffer), do: false

  defp capped_body(current, data) do
    remaining = max(65_536 - byte_size(current), 0)
    current <> binary_part(data, 0, min(byte_size(data), remaining))
  end
end
