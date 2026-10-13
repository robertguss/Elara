defmodule Elara.MCP.Protocol do
  @moduledoc false

  @modern "2026-07-28"
  @legacy ~w(2025-11-25 2025-06-18 2025-03-26 2024-11-05)

  def modern, do: @modern
  def legacy, do: @legacy

  def server_info(result) do
    meta =
      case result["_meta"] do
        %{} = meta -> meta["io.modelcontextprotocol/serverInfo"]
        _ -> nil
      end

    info = result["serverInfo"] || meta

    case info do
      %{"name" => name, "version" => version} when is_binary(name) and is_binary(version) ->
        %{"name" => name, "version" => version}

      _ ->
        nil
    end
  end

  def request(version, id, method, params) do
    params =
      if version == @modern do
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => version,
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "io.modelcontextprotocol/clientInfo" => %{"name" => "elara", "version" => "0.1.0"}
        })
      else
        params
      end

    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  def response(%{"jsonrpc" => "2.0", "id" => id, "result" => result} = message, id)
      when is_map(result) and not is_map_key(message, "error") do
    case Map.get(result, "resultType", "complete") do
      "complete" -> {:ok, result}
      _ -> {:indeterminate, :unsupported_input_required}
    end
  end

  def response(
        %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code} = error} = message,
        id
      )
      when is_integer(code) and not is_map_key(message, "result"), do: {:rpc_error, error}

  def response(%{"jsonrpc" => "2.0", "method" => _} = message, _id)
      when not is_map_key(message, "id"), do: :notification

  def response(_, _), do: {:indeterminate, :invalid_response}

  def catalog(tools) when is_list(tools) do
    valid =
      Enum.all?(tools, fn
        %{"name" => name, "inputSchema" => schema} ->
          is_binary(name) and name != "" and is_map(schema)

        _ ->
          false
      end)

    if valid do
      names = Enum.map(tools, & &1["name"])

      if length(names) == length(Enum.uniq(names)),
        do: {:ok, Enum.sort_by(tools, & &1["name"])},
        else: {:error, :invalid_catalog}
    else
      {:error, :invalid_catalog}
    end
  end

  def catalog(_), do: {:error, :invalid_catalog}

  def header_value(value) do
    text = if is_binary(value), do: value, else: to_string(value)

    if String.trim(text) == text and Regex.match?(~r/\A[\x20-\x7e]*\z/, text) and
         not (String.starts_with?(text, "=?base64?") and String.ends_with?(text, "?=")),
       do: text,
       else: "=?base64?#{Base.encode64(text)}?="
  end

  # Header annotations must be statically reachable through properties only.
  def tool_headers(schema, args) do
    with {:ok, paths} <- annotations(schema, [], false),
         names = Enum.map(paths, fn {name, _, _} -> String.downcase(name) end),
         true <- length(names) == length(Enum.uniq(names)) do
      Enum.reduce_while(paths, {:ok, []}, fn {name, path, type}, {:ok, headers} ->
        value =
          Enum.reduce(path, args, fn key, value ->
            if is_map(value), do: Map.get(value, key), else: :invalid
          end)

        cond do
          value == nil ->
            {:cont, {:ok, headers}}

          primitive?(value, type) ->
            {:cont, {:ok, [{"mcp-param-" <> name, header_value(value)} | headers]}}

          true ->
            {:halt, {:error, :invalid_header_argument}}
        end
      end)
    else
      _ -> {:error, :invalid_header_annotation}
    end
  end

  defp annotations(map, path, forbidden) when is_map(map) do
    own =
      case Map.get(map, "x-mcp-header") do
        nil ->
          {:ok, []}

        name when is_binary(name) ->
          if not forbidden and path != [] and map["type"] in ["string", "integer", "boolean"] and
               Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, name),
             do: {:ok, [{name, path, map["type"]}]},
             else: {:error, :invalid_header_annotation}

        _ ->
          {:error, :invalid_header_annotation}
      end

    with {:ok, _} <- own do
      Enum.reduce_while(map, own, fn {key, value}, {:ok, acc} ->
        result =
          if key == "properties" and is_map(value) do
            Enum.reduce_while(value, {:ok, []}, fn {name, child}, {:ok, found} ->
              case annotations(child, path ++ [name], forbidden) do
                {:ok, extra} -> {:cont, {:ok, found ++ extra}}
                error -> {:halt, error}
              end
            end)
          else
            annotations(value, path, true)
          end

        case result do
          {:ok, extra} -> {:cont, {:ok, acc ++ extra}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp annotations(list, path, forbidden) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn child, {:ok, acc} ->
      case annotations(child, path, forbidden) do
        {:ok, extra} -> {:cont, {:ok, acc ++ extra}}
        error -> {:halt, error}
      end
    end)
  end

  defp annotations(_, _, _), do: {:ok, []}
  defp primitive?(v, "string"), do: is_binary(v)
  defp primitive?(v, "boolean"), do: is_boolean(v)
  defp primitive?(v, "integer"), do: is_integer(v) and abs(v) <= 9_007_199_254_740_991
end
