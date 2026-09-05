defmodule Elara.ProviderLegacyStreamTest do
  use ExUnit.Case, async: false

  defmodule PausedCodexStream do
    # Exercise the production Codex SSE parser with a deterministic completion gate.
    # No credentials or live HTTP are needed to test the session/socket projection.
    def stream(owner, _request, sink) do
      item = %{
        "id" => "m",
        "type" => "message",
        "role" => "assistant",
        "phase" => "final_answer",
        "content" => [%{"type" => "output_text", "text" => "legacy answer"}]
      }

      events = [
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => item},
        %{
          "type" => "response.output_text.delta",
          "output_index" => 0,
          "delta" => "legacy answer"
        },
        %{"type" => "response.completed", "response" => %{"output" => [item]}}
      ]

      frames = Enum.map(events, &("data: " <> JSON.encode!(&1) <> "\n\n"))

      result =
        Elara.Provider.OpenAICodex.parse_stream_chunks(frames, fn delta ->
          :ok = sink.(delta)

          if is_binary(delta) do
            send(owner, {:legacy_binary_pending, self()})

            receive do
              :finish -> :ok
            after
              5000 -> raise "completion gate timed out"
            end
          end

          :ok
        end)

      case result do
        {:ok, assistant} -> {:ok, assistant, owner}
        {:error, error} -> {:error, error, owner}
      end
    end
  end

  test "CLI, v1 and unnegotiated v2 receive answer bytes before provider completion" do
    provider = {PausedCodexStream, self()}
    {:ok, server} = Elara.Server.start_link(port: 0, provider: provider)

    for version <- [1, 2] do
      {:ok, session} = Elara.start_session(provider: provider, tools: [], persist: false)
      :ok = Elara.subscribe(session)

      {:ok, socket} =
        :gen_tcp.connect({127, 0, 0, 1}, Elara.Server.port(server), [
          :binary,
          packet: :line,
          active: false
        ])

      :ok =
        :gen_tcp.send(
          socket,
          Elara.Protocol.encode(%{
            "version" => version,
            "command" => "attach",
            "session_id" => session,
            "mode" => "observe"
          })
        )

      assert %{"type" => "attached"} = recv(socket)
      :ok = Elara.ask_async(session, "question")
      assert_receive {:legacy_binary_pending, provider_task}, 2000
      assert receive_answer(socket) == "legacy answer"
      assert Elara.materialized_view(session)["turn"]["state"] == "calling_provider"
      assert_receive {:elara, ^session, {:content_delta, _id, "legacy answer"} = event}
      assert IO.iodata_to_binary(Elara.CLI.render(event)) == "legacy answer"
      send(provider_task, :finish)
      assert_receive {:elara, ^session, {:turn_ended, {:completed, "legacy answer"}}}, 2000

      assert_receive {:elara, ^session,
                      {:message_appended, %Elara.Message.Assistant{}, :streamed} = completed}

      assert IO.iodata_to_binary(Elara.CLI.render(completed)) == "\n"
      :gen_tcp.close(socket)
      {:ok, pid} = Elara.session_pid(session)
      GenServer.stop(pid)
    end
  end

  defp recv(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2000)
    JSON.decode!(line)
  end

  defp receive_answer(socket) do
    case recv(socket) do
      %{"type" => "event", "event" => %{"kind" => "content_delta", "text" => text}} ->
        text

      %{"type" => "patch", "ops" => ops} ->
        refute Enum.any?(ops, &(&1["op"] == "set_provider_view"))

        case Enum.find(ops, &(&1["op"] == "append_content_delta")) do
          nil -> receive_answer(socket)
          delta -> delta["text"]
        end

      _ ->
        receive_answer(socket)
    end
  end
end
