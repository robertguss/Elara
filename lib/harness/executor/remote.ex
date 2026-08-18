defmodule Harness.Executor.Remote do
  @moduledoc "Authenticated TCP client for a narrow remote-worker protocol."

  @behaviour Harness.Executor

  alias Harness.Executor.Request

  @protocol_version 1

  @impl true
  def execute(config, %Request{} = request, _tool) do
    host = Map.get(config, :host, {127, 0, 0, 1})
    port = Map.fetch!(config, :port)
    token = Map.fetch!(config, :token)
    timeout = max(request.deadline_ms - System.system_time(:millisecond), 1)

    with {:ok, socket} <-
           :gen_tcp.connect(host, port, [:binary, packet: :line, active: false], timeout),
         :ok <-
           :gen_tcp.send(
             socket,
             encode(%{
               "version" => @protocol_version,
               "token" => token,
               "request" => Request.to_map(request)
             })
           ),
         {:ok, line} <- :gen_tcp.recv(socket, 0, timeout),
         {:ok, response} <- decode(line) do
      :gen_tcp.close(socket)
      decode_response(response)
    else
      {:error, reason} -> {:executor_error, :transport, format_reason(reason)}
    end
  end

  defp decode_response(%{"type" => "result", "outcome" => %{"ok" => text}})
       when is_binary(text),
       do: {:ok, text}

  defp decode_response(%{"type" => "result", "outcome" => %{"error" => text}})
       when is_binary(text),
       do: {:error, text}

  defp decode_response(%{"type" => "error", "error" => error}) when is_binary(error),
    do: {:executor_error, :rejected, error}

  defp decode_response(_response),
    do: {:executor_error, :transport, "worker returned an invalid response"}

  defp encode(message), do: [JSON.encode!(message), "\n"]

  defp decode(line) do
    case JSON.decode(line) do
      {:ok, %{} = message} -> {:ok, message}
      _ -> {:error, :invalid_response}
    end
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
