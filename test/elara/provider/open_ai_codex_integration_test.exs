defmodule Elara.Provider.OpenAICodexIntegrationTest do
  use ExUnit.Case, async: false

  alias Elara.Auth.OpenAICodex, as: Tokens
  alias Elara.Provider.OpenAICodex
  alias Elara.Session.Store
  alias Elara.Tool

  defmodule EchoTool do
    def run(%{"value" => value}, _context), do: {:ok, value}
  end

  setup do
    previous = Application.get_env(:elara, :sessions_root)

    root =
      Path.join(System.tmp_dir!(), "elara-openai-session-#{System.unique_integer([:positive])}")

    Application.put_env(:elara, :sessions_root, root)

    on_exit(fn ->
      if previous do
        Application.put_env(:elara, :sessions_root, previous)
      else
        Application.delete_env(:elara, :sessions_root)
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "accepted settings are inherited by the existing child creation config" do
    tokens = %Tokens{
      access_token: "fake",
      refresh_token: "fake",
      expires_at: System.system_time(:second) + 3600,
      account_id: "fake"
    }

    {:ok, session} =
      Elara.start_session(
        provider: {OpenAICodex, OpenAICodex.new(tokens)},
        tools: [],
        persist: false
      )

    assert :ok =
             Elara.set_provider_settings(session, %{"model" => "gpt-5.4-mini", "effort" => "high"})

    assert {OpenAICodex, %{model: "gpt-5.4-mini", effort: "high"}} =
             Elara.child_config(session).provider

    assert {:error, :unsupported_provider_settings} =
             Elara.set_provider_settings(session, %{"model" => "unsupported", "effort" => "ultra"})

    assert {OpenAICodex, %{model: "gpt-5.4-mini", effort: "high"}} =
             Elara.child_config(session).provider

    {:ok, pid} = Elara.session_pid(session)
    GenServer.stop(pid)
  end

  test "public session streams tool continuation and resumes native state", %{root: root} do
    {tool_response, tool_output} = tool_stream()
    {second_response, second_output} = success_stream("tool complete", "msg_2")
    {third_response, _third_output} = success_stream("resumed", "msg_3")

    {server, port} =
      start_http_server(self(), [tool_response, second_response, third_response])

    tokens = %Tokens{
      access_token: "access-token",
      refresh_token: "refresh-token",
      expires_at: System.system_time(:second) + 3_600,
      account_id: "account-123"
    }

    provider =
      {OpenAICodex,
       OpenAICodex.new(tokens,
         model: "gpt-test",
         base_url: "http://127.0.0.1:#{port}/backend-api"
       )}

    cwd = Path.join(root, "project")

    assert {:ok, session} =
             Elara.start_session(
               provider: provider,
               tools: [echo_tool()],
               plugins: [],
               cwd: cwd,
               system: "system"
             )

    assert {:ok, "tool complete"} = Elara.ask(session, "hello")

    assert_receive {:request, "/backend-api/codex/responses", headers, first_raw_body}
    assert headers["authorization"] == "Bearer access-token"
    assert headers["chatgpt-account-id"] == "account-123"
    assert headers["originator"] == "elara"

    assert {:ok, first_body} = JSON.decode(first_raw_body)
    assert first_body["model"] == "gpt-test"
    assert String.starts_with?(first_body["instructions"], "system\n\n")
    assert first_body["instructions"] =~ "Project instruction policy:"
    assert first_body["input"] == [user_input("hello")]
    assert [%{"name" => "echo", "strict" => false}] = first_body["tools"]

    assert_receive {:request, "/backend-api/codex/responses", _headers, second_raw_body}
    assert {:ok, second_body} = JSON.decode(second_raw_body)
    assert second_body["instructions"] == first_body["instructions"]

    assert second_body["input"] ==
             [user_input("hello") | tool_output] ++
               [
                 %{
                   "type" => "function_call_output",
                   "call_id" => "call_1",
                   "output" => "tool-output"
                 }
               ]

    assert {:ok, info} = Store.newest(cwd)
    {:ok, pid} = Elara.session_pid(session)
    GenServer.stop(pid)

    assert {:ok, resumed} =
             Elara.start_session(
               provider: provider,
               tools: [echo_tool()],
               plugins: [],
               cwd: cwd,
               system: "system",
               resume: info.path
             )

    assert {:ok, "resumed"} = Elara.ask(resumed, "next")

    assert_receive {:request, "/backend-api/codex/responses", _headers, third_raw_body}
    assert {:ok, third_body} = JSON.decode(third_raw_body)
    assert third_body["instructions"] == first_body["instructions"]

    assert third_body["input"] ==
             [user_input("hello") | tool_output] ++
               [
                 %{
                   "type" => "function_call_output",
                   "call_id" => "call_1",
                   "output" => "tool-output"
                 }
               ] ++ second_output ++ [user_input("next")]

    {:ok, pid} = Elara.session_pid(resumed)
    GenServer.stop(pid)
    assert_receive {:http_server_done, ^server}
  end

  defp echo_tool do
    %Tool{
      name: "echo",
      description: "Return a value",
      parameters: %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}},
        "required" => ["value"]
      },
      run: {EchoTool, :run}
    }
  end

  defp user_input(text) do
    %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}
  end

  defp start_http_server(owner, response_bodies) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        Enum.each(response_bodies, fn response_body ->
          {:ok, socket} = :gen_tcp.accept(listener)
          {path, headers, body} = receive_request(socket)
          send(owner, {:request, path, headers, body})

          response = [
            "HTTP/1.1 200 OK\r\n",
            "content-type: text/event-stream\r\n",
            "content-length: #{byte_size(response_body)}\r\n",
            "connection: close\r\n\r\n",
            response_body
          ]

          :ok = :gen_tcp.send(socket, response)
          :gen_tcp.close(socket)
        end)

        :gen_tcp.close(listener)
        send(owner, {:http_server_done, self()})
      end)

    {server, port}
  end

  defp receive_request(socket) do
    {header, buffered_body} = receive_headers(socket, "")
    [request_line | header_lines] = String.split(header, "\r\n", trim: true)
    [_method, path, _version] = String.split(request_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    content_length = headers |> Map.fetch!("content-length") |> String.to_integer()
    body = receive_body(socket, buffered_body, content_length)
    {path, headers, body}
  end

  defp receive_headers(socket, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {index, 4} ->
        header = binary_part(buffer, 0, index)
        body_offset = index + 4
        body = binary_part(buffer, body_offset, byte_size(buffer) - body_offset)
        {header, body}

      :nomatch ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
        receive_headers(socket, buffer <> data)
    end
  end

  defp receive_body(_socket, body, content_length) when byte_size(body) >= content_length,
    do: binary_part(body, 0, content_length)

  defp receive_body(socket, body, content_length) do
    {:ok, data} = :gen_tcp.recv(socket, content_length - byte_size(body), 2_000)
    receive_body(socket, body <> data, content_length)
  end

  defp tool_stream do
    output = [
      %{
        "type" => "reasoning",
        "id" => "rs_1",
        "summary" => [],
        "encrypted_content" => "encrypted"
      },
      %{
        "type" => "function_call",
        "id" => "fc_1",
        "call_id" => "call_1",
        "name" => "echo",
        "arguments" => ~s({"value":"tool-output"})
      }
    ]

    events = [
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_1",
          "status" => "completed",
          "output" => output,
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
        }
      }
    ]

    {encode_events(events), output}
  end

  defp success_stream(text, id) do
    output = [
      %{
        "type" => "message",
        "id" => id,
        "role" => "assistant",
        "status" => "completed",
        "content" => [%{"type" => "output_text", "text" => text}]
      }
    ]

    events = [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "type" => "message",
          "id" => id,
          "role" => "assistant",
          "status" => "in_progress",
          "content" => []
        }
      },
      %{"type" => "response.output_text.delta", "output_index" => 0, "delta" => text},
      %{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => hd(output)
      },
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_#{id}",
          "status" => "completed",
          "output" => output,
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
        }
      }
    ]

    {encode_events(events), output}
  end

  defp encode_events(events),
    do: Enum.map_join(events, fn event -> "data: #{JSON.encode!(event)}\n\n" end)
end
