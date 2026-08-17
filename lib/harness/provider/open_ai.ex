defmodule Harness.Provider.OpenAI do
  @moduledoc "OpenAI-compatible chat completions adapter."

  @behaviour Harness.Provider

  alias Harness.Message
  alias Harness.Message.{Assistant, ToolCall, ToolResult, User}
  alias Harness.Provider
  alias Harness.Provider.Error
  alias Harness.Tool

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
      {:ok, assistant} ->
        {:ok, assistant, config}

      {:error, %Error{kind: :http, message: msg} = err} ->
        if String.starts_with?(msg, "403") do
          {:error,
           %Error{
             kind: :entitlement,
             message:
               "HTTP 403: this account cannot use the API. Set XAI_API_KEY (or HARNESS_API_KEY). Re-login will not help."
           }, config}
        else
          {:error, err, config}
        end

      {:error, err} ->
        {:error, err, config}
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
    {:error, %Error{kind: :http, message: "#{status} #{snippet}"}}
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
    base = %{"role" => "assistant", "content" => text}

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

  defp body_snippet(body) when is_binary(body) do
    body |> String.replace(~r/\s+/, " ") |> String.slice(0, 200)
  end

  defp body_snippet(body), do: inspect(body) |> String.slice(0, 200)
end
