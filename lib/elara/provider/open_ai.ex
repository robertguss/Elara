defmodule Elara.Provider.OpenAI do
  @moduledoc "OpenAI-compatible chat completions adapter."

  @behaviour Elara.Provider

  alias Elara.Message
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
  alias Elara.Provider
  alias Elara.Provider.Error
  alias Elara.Tool

  @derive {Inspect, except: [:api_key]}
  defstruct [:api_key, :base_url, :model]

  @type config :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          model: String.t()
        }

  @impl true
  def chat(%__MODULE__{} = config, %Provider.Request{} = request) do
    url = String.trim_trailing(config.base_url, "/") <> "/chat/completions"
    body = build_body(config, request)

    result =
      Req.post(url,
        auth: {:bearer, config.api_key},
        json: body,
        decode_body: false,
        receive_timeout: 120_000
      )

    case parse_response(result) do
      {:ok, assistant} -> {:ok, assistant, config}
      {:error, err} -> {:error, err, config}
    end
  end

  @impl true
  def stream(%__MODULE__{} = config, %Provider.Request{} = request, sink)
      when is_function(sink, 1) do
    url = String.trim_trailing(config.base_url, "/") <> "/chat/completions"
    body = config |> build_body(request) |> Map.put("stream", true)
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
            auth: {:bearer, config.api_key},
            json: body,
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
      {:error, error} -> {:error, error, config}
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

  @doc "Pure. Request to OpenAI wire body."
  @spec build_body(config(), Provider.Request.t()) :: map()
  def build_body(%__MODULE__{} = config, %Provider.Request{} = request) do
    messages =
      [%{"role" => "system", "content" => request.system}] ++
        Enum.map(request.messages, &encode_message/1)

    body = %{
      "model" => config.model,
      "messages" => messages
    }

    case request.tools do
      [] -> body
      tools -> Map.put(body, "tools", Enum.map(tools, &encode_tool/1))
    end
  end

  @doc "Pure. Wire response to domain."
  @spec parse_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          {:ok, Assistant.t()} | {:error, Error.t()}
  def parse_response({:error, exception}) do
    {:error, %Error{kind: :transport, message: Exception.message(exception)}}
  end

  def parse_response({:ok, %Req.Response{status: status, body: body}}) when status != 200 do
    snippet = body_snippet(body)
    {:error, %Error{kind: :http, status: status, message: "#{status} #{snippet}"}}
  end

  def parse_response({:ok, %Req.Response{status: 200, body: body}}) do
    with {:ok, decoded} <- decode_body(body),
         {:ok, message} <- pick_message(decoded),
         {:ok, assistant} <- to_assistant(message) do
      {:ok, assistant}
    else
      {:error, %Error{} = err} -> {:error, err}
    end
  end

  defp encode_message(%User{text: text}), do: %{"role" => "user", "content" => text}

  defp encode_message(%Assistant{text: text, tool_calls: calls}) do
    # xAI rejects assistant tool-call messages with content: null.
    base = %{"role" => "assistant", "content" => text || ""}

    case calls do
      [] ->
        base

      calls ->
        Map.put(base, "tool_calls", Enum.map(calls, &encode_tool_call/1))
    end
  end

  defp encode_message(%ToolResult{call_id: id, outcome: outcome}) do
    content =
      case outcome do
        {:ok, text} -> text
        {:error, text} -> "ERROR: " <> text
        {:indeterminate, text} -> "INDETERMINATE: " <> text
      end

    %{"role" => "tool", "tool_call_id" => id, "content" => content}
  end

  defp encode_tool_call(%ToolCall{id: id, name: name, args: args}) do
    arguments =
      case args do
        {:ok, map} -> JSON.encode!(map)
        {:malformed, raw} -> raw
      end

    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => arguments}
    }
  end

  defp encode_tool(%Tool{name: name, description: description, parameters: parameters}) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => parameters
      }
    }
  end

  defp decode_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _} ->
        {:error, %Error{kind: :bad_response, message: "response JSON was not an object"}}

      {:error, err} ->
        {:error, %Error{kind: :bad_response, message: inspect(err)}}
    end
  end

  defp decode_body(body) when is_map(body), do: {:ok, body}
  defp decode_body(other), do: {:error, %Error{kind: :bad_response, message: inspect(other)}}

  defp pick_message(%{"choices" => [%{"message" => message} | _]}) when is_map(message),
    do: {:ok, message}

  defp pick_message(_), do: {:error, %Error{kind: :bad_response, message: "missing choices"}}

  defp to_assistant(message) do
    text =
      case message do
        %{"content" => content} when is_binary(content) -> content
        %{"content" => nil} -> nil
        _ -> nil
      end

    tool_calls =
      message
      |> Map.get("tool_calls", [])
      |> List.wrap()
      |> Enum.map(&parse_tool_call/1)

    case Message.assistant(text, tool_calls) do
      {:ok, assistant} ->
        {:ok, assistant}

      {:error, :empty_assistant} ->
        {:error, %Error{kind: :bad_response, message: "empty assistant message"}}
    end
  end

  defp parse_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => arguments}}) do
    args =
      cond do
        is_map(arguments) ->
          {:ok, arguments}

        is_binary(arguments) ->
          case JSON.decode(arguments) do
            {:ok, map} when is_map(map) -> {:ok, map}
            _ -> {:malformed, arguments}
          end

        true ->
          {:malformed, inspect(arguments)}
      end

    %ToolCall{id: id, name: name, args: args}
  end

  defp parse_tool_call(other) do
    %ToolCall{id: "unknown", name: "unknown", args: {:malformed, inspect(other)}}
  end

  defp new_stream_state do
    %{buffer: "", text: "", calls: %{}, done: false, error: nil, error_body: ""}
  end

  defp consume_stream_data(%{done: true} = state, _data, _sink), do: {:ok, state}

  defp consume_stream_data(state, data, sink) when is_binary(data) do
    normalized =
      (state.buffer <> data)
      |> :binary.replace("\r\n", "\n", [:global])
      |> :binary.replace("\r", "\n", [:global])

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
      data == "" ->
        {:ok, state}

      data == "[DONE]" ->
        {:ok, %{state | done: true}}

      true ->
        with {:ok, decoded} <- decode_stream_json(data),
             {:ok, state, deltas} <- merge_stream_event(state, decoded) do
          Enum.each(deltas, fn text -> :ok = sink.(text) end)
          {:ok, state}
        else
          {:error, %Error{} = error} -> {:error, error, state}
        end
    end
  end

  defp decode_stream_json(data) do
    case JSON.decode(data) do
      {:ok, %{} = decoded} ->
        {:ok, decoded}

      {:ok, _other} ->
        {:error, %Error{kind: :bad_response, message: "SSE data was not an object"}}

      {:error, error} ->
        {:error, %Error{kind: :bad_response, message: "invalid SSE JSON: #{inspect(error)}"}}
    end
  end

  defp merge_stream_event(state, %{"choices" => []}), do: {:ok, state, []}

  defp merge_stream_event(state, %{"choices" => [%{"delta" => delta} | _]})
       when is_map(delta) do
    with {:ok, text} <- stream_text(delta),
         {:ok, calls} <- merge_stream_calls(state.calls, Map.get(delta, "tool_calls", [])) do
      state = %{state | text: state.text <> text, calls: calls}
      {:ok, state, if(text == "", do: [], else: [text])}
    end
  end

  defp merge_stream_event(_state, %{"error" => error}) do
    {:error, %Error{kind: :bad_response, message: "stream error: #{inspect(error)}"}}
  end

  defp merge_stream_event(_state, _decoded) do
    {:error, %Error{kind: :bad_response, message: "missing streaming choices"}}
  end

  defp stream_text(%{"content" => text}) when is_binary(text), do: {:ok, text}
  defp stream_text(%{"content" => nil}), do: {:ok, ""}
  defp stream_text(delta) when not is_map_key(delta, "content"), do: {:ok, ""}

  defp stream_text(_delta) do
    {:error, %Error{kind: :bad_response, message: "invalid streaming content"}}
  end

  defp merge_stream_calls(calls, fragments) when is_list(fragments) do
    Enum.reduce_while(fragments, {:ok, calls}, fn
      %{"index" => index} = fragment, {:ok, calls}
      when is_integer(index) and index >= 0 ->
        previous = Map.get(calls, index, %{id: nil, name: nil, arguments: ""})
        function = Map.get(fragment, "function", %{})

        with true <- is_map(function),
             {:ok, id} <- stream_value(fragment, "id", previous.id),
             {:ok, name} <- stream_value(function, "name", previous.name),
             {:ok, arguments} <- stream_value(function, "arguments", "") do
          call = %{
            id: id,
            name: name,
            arguments: previous.arguments <> arguments
          }

          {:cont, {:ok, Map.put(calls, index, call)}}
        else
          _invalid -> {:halt, bad_stream_calls()}
        end

      _fragment, _acc ->
        {:halt, bad_stream_calls()}
    end)
  end

  defp merge_stream_calls(_calls, _fragments), do: bad_stream_calls()

  defp stream_value(map, key, fallback) do
    case Map.fetch(map, key) do
      :error -> {:ok, fallback}
      {:ok, nil} -> {:ok, fallback}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _invalid} -> :error
    end
  end

  defp bad_stream_calls do
    {:error, %Error{kind: :bad_response, message: "invalid streaming tool calls"}}
  end

  defp finish_stream({:error, exception}, _state) do
    {:error, %Error{kind: :transport, message: Exception.message(exception)}}
  end

  defp finish_stream({:ok, %Req.Response{status: status}}, state) when status != 200 do
    snippet = body_snippet(state.error_body)
    {:error, %Error{kind: :http, status: status, message: "#{status} #{snippet}"}}
  end

  defp finish_stream({:ok, %Req.Response{status: 200}}, %{error: %Error{} = error}),
    do: {:error, error}

  defp finish_stream({:ok, %Req.Response{status: 200}}, %{done: false}) do
    {:error, %Error{kind: :bad_response, message: "stream ended before [DONE]"}}
  end

  defp finish_stream({:ok, %Req.Response{status: 200}}, state) do
    cond do
      not blank_stream_buffer?(state.buffer) ->
        {:error, %Error{kind: :bad_response, message: "stream ended with an incomplete frame"}}

      true ->
        stream_assistant(state)
    end
  end

  defp stream_assistant(state) do
    calls =
      state.calls
      |> Enum.sort_by(fn {index, _call} -> index end)
      |> Enum.map(fn {_index, call} ->
        %{"id" => call.id, "function" => %{"name" => call.name, "arguments" => call.arguments}}
      end)

    if Enum.all?(calls, fn call ->
         is_binary(call["id"]) and is_binary(get_in(call, ["function", "name"]))
       end) do
      text = if state.text == "", do: nil, else: state.text
      to_assistant(%{"content" => text, "tool_calls" => calls})
    else
      {:error, %Error{kind: :bad_response, message: "incomplete streaming tool call"}}
    end
  end

  defp capped_body(body, data) do
    (body <> data)
    |> binary_part(0, min(byte_size(body <> data), 8_192))
  end

  defp strip_sse_space(" " <> data), do: data
  defp strip_sse_space(data), do: data

  defp blank_stream_buffer?(<<>>), do: true

  defp blank_stream_buffer?(<<byte, rest::binary>>) when byte in [?\s, ?\t, ?\n],
    do: blank_stream_buffer?(rest)

  defp blank_stream_buffer?(_buffer), do: false

  defp body_snippet(body) when is_binary(body) do
    body |> String.replace(~r/\s+/, " ") |> String.slice(0, 200)
  end

  defp body_snippet(body), do: inspect(body) |> String.slice(0, 200)
end
