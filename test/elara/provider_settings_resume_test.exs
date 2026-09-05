defmodule Elara.ProviderSettingsResumeTest do
  use ExUnit.Case, async: false

  alias Elara.Auth.OpenAICodex, as: Tokens
  alias Elara.Provider.OpenAICodex
  alias Elara.Session.Store

  @saved %{"model" => "gpt-5.4-mini", "effort" => "high"}

  defmodule RecordingProvider do
    @behaviour Elara.Provider
    def chat(owner, request) do
      send(owner, {:provider_request, request})
      {:ok, %Elara.Message.Assistant{text: "ordinary"}, owner}
    end
  end

  setup do
    previous = Application.get_env(:elara, :sessions_root)

    root =
      Path.join(System.tmp_dir!(), "elara-settings-resume-#{System.unique_integer([:positive])}")

    Application.put_env(:elara, :sessions_root, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:elara, :sessions_root, previous),
        else: Application.delete_env(:elara, :sessions_root)

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "in-process resume restores target settings in the next real Codex request", %{root: root} do
    {response, _} = success_stream("restored", "msg_resume")
    {_server, port} = start_http_server(self(), [response])
    provider = codex("http://127.0.0.1:#{port}/backend-api")
    path = saved_store(root, provider)
    session = start_session(root, provider)
    assert :ok = Elara.set_provider_settings(session, %{"model" => "gpt-5.5", "effort" => "low"})
    assert :ok = Elara.subscribe(session)
    assert {:ok, []} = Elara.resume(session, path)
    assert Elara.materialized_view(session)["provider_view"]["next_request"] == @saved
    assert_receive {:elara, ^session, :provider_view_changed}
    assert {:ok, "restored"} = Elara.ask(session, "next")
    assert_receive {:request, _, _, raw}
    request = JSON.decode!(raw)
    assert request["model"] == @saved["model"]
    assert request["reasoning"]["effort"] == @saved["effort"]
    assert {:ok, store} = Store.open(path, root)
    assert store.provider_settings == @saved
    stop_session(session)
  end

  test "failed settings persistence leaves the effective next request unchanged", %{root: root} do
    session = start_session(root, codex("http://127.0.0.1:1/backend-api"), name: "write-failure")
    {:ok, info} = Store.newest(root)
    before_view = Elara.materialized_view(session)["provider_view"]
    before_provider = Elara.child_config(session).provider
    saved_bytes = File.read!(info.path)
    backup = info.path <> ".backup"
    File.rename!(info.path, backup)
    File.mkdir!(info.path)

    try do
      assert :ok = Elara.subscribe(session)
      assert {:error, :eisdir} = Elara.set_provider_settings(session, @saved)
      assert Elara.materialized_view(session)["provider_view"] == before_view
      assert Elara.child_config(session).provider == before_provider
      refute_receive {:elara, ^session, :provider_view_changed}, 30
      assert File.read!(backup) == saved_bytes
      assert Path.wildcard(info.path <> ".tmp.*") == []
    after
      File.rmdir!(info.path)
      File.rename!(backup, info.path)
      stop_session(session)
    end
  end

  for mode <- [:startup, :in_process] do
    test "#{mode} resume under an ordinary provider keeps settings unavailable", %{root: root} do
      path = saved_store(root, codex("http://127.0.0.1:1/backend-api"))
      provider = {RecordingProvider, self()}

      session =
        case unquote(mode) do
          :startup ->
            start_session(root, provider, resume: path)

          :in_process ->
            session = start_session(root, provider)
            assert {:ok, []} = Elara.resume(session, path)
            session
        end

      view = Elara.materialized_view(session)["provider_view"]
      assert view["next_request"] == nil
      assert view["catalog"] == []

      assert {:error, :provider_controls_unavailable} =
               Elara.set_provider_settings(session, @saved)

      assert {:ok, "ordinary"} = Elara.ask(session, "next")
      assert_receive {:provider_request, request}
      assert request.settings == nil
      assert {:ok, store} = Store.open(path, root)
      assert store.provider_settings == nil
      stop_session(session)
    end
  end

  defp start_session(root, provider, extra \\ []) do
    {:ok, session} =
      Elara.start_session(
        [provider: provider, cwd: root, tools: [], plugins: [], system: "system"] ++ extra
      )

    session
  end

  defp saved_store(root, provider) do
    session = start_session(root, provider, name: "target")
    assert :ok = Elara.set_provider_settings(session, @saved)
    {:ok, info} = Store.newest(root)
    stop_session(session)
    info.path
  end

  defp stop_session(session) do
    {:ok, pid} = Elara.session_pid(session)
    GenServer.stop(pid)
  end

  defp codex(base_url) do
    tokens = %Tokens{
      access_token: "fake",
      refresh_token: "fake",
      account_id: "fake",
      expires_at: System.system_time(:second) + 3600
    }

    {OpenAICodex, OpenAICodex.new(tokens, model: "gpt-5.5", base_url: base_url)}
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
