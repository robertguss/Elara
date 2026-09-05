defmodule Elara.ProviderVisibilityProductTest do
  use ExUnit.Case, async: false

  alias Elara.Auth.OpenAICodex, as: Tokens
  alias Elara.Provider.OpenAICodex
  alias Elara.Session.Store

  defmodule InterruptedPublicProvider do
    @behaviour Elara.Provider

    def chat(owner, _request),
      do: {:error, %Elara.Provider.Error{kind: :bad_response, message: "stream required"}, owner}

    def stream(owner, _request, sink) do
      :ok =
        sink.(
          {:public_content,
           %{
             "kind" => "reasoning_summary",
             "item_id" => "synthetic-summary",
             "output_index" => 0,
             "part_index" => 0,
             "text" => "Partial public summary é 👩‍💻"
           }}
        )

      receive do
        :finish -> chat(owner, nil)
      end
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "elara-provider-pty-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous = Application.get_env(:elara, :sessions_root)
    Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:elara, :sessions_root, previous),
        else: Application.delete_env(:elara, :sessions_root)

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  @tag timeout: 120_000
  test "subscription content and request settings survive real HTTP, terminal interaction, and resume",
       %{root: root} do
    binary = Mix.Tasks.Elara.Tui.binary!()

    child =
      Port.open(
        {:spawn_executable,
         String.to_charlist(System.find_executable("python3") || flunk("python3 is required"))},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: [Path.expand("../support/provider_visibility_pty.py", __DIR__), binary],
          env: [
            {~c"ELARA_TUI_STATE_DIR", String.to_charlist(Path.join(root, "state"))},
            {~c"ELARA_TUI_APPEARANCE_FILE",
             String.to_charlist(Path.join(root, "appearance.json"))}
          ]
        ]
      )

    on_exit(fn ->
      try do
        Port.close(child)
      rescue
        ArgumentError -> :ok
      end
    end)

    {line, buffered} = read_line(child, "")
    assert {:ok, %{"http_port" => http_port}} = JSON.decode(line)

    tokens = %Tokens{
      access_token: "provider-product-access-canary",
      refresh_token: "provider-product-refresh-canary",
      account_id: "test-account",
      expires_at: System.system_time(:second) + 3_600
    }

    provider =
      {OpenAICodex,
       OpenAICodex.new(tokens,
         model: "gpt-5.5",
         base_url: "http://127.0.0.1:#{http_port}/backend-api"
       )}

    {:ok, session} =
      Elara.start_session(provider: provider, tools: [], plugins: [], cwd: root, system: "test")

    on_exit(fn -> stop_session(session) end)

    assert {:ok, "HISTORY_FINAL_ONLY"} = Elara.ask(session, "earlier provider turn")
    {:ok, server} = Elara.Server.start_link(port: 0, provider: provider)

    Port.command(
      child,
      JSON.encode!(%{session: session, port: Elara.Server.port(server)}) <> "\n"
    )

    {output, status} = await_exit(child, buffered)
    assert status == 0, output
    assert output =~ "Provider visibility PTY passed"

    {:ok, info} = Store.newest(root)
    {:ok, pid} = Elara.session_pid(session)
    GenServer.stop(pid)

    {:ok, resumed} =
      Elara.start_session(
        provider: provider,
        tools: [],
        plugins: [],
        cwd: root,
        system: "test",
        resume: info.path
      )

    on_exit(fn -> stop_session(resumed) end)

    view = Elara.materialized_view(resumed)

    assert view["provider_view"]["next_request"] == %{
             "model" => "gpt-5.4-mini",
             "effort" => "high"
           }

    assert view["provider_view"]["usage"]["session_totals"] == %{
             "input_tokens" => 360,
             "output_tokens" => 90,
             "total_tokens" => 450,
             "cached_input_tokens" => 24,
             "reasoning_tokens" => 21
           }

    assert JSON.encode!(view) =~ "HISTORY_SUMMARY_ONLY"
    refute JSON.encode!(view) =~ "PRIVATE_REASONING_CANARY"
    {:ok, pid} = Elara.session_pid(resumed)
    GenServer.stop(pid)
  end

  test "an interrupted public summary survives stopping and reloading its session", %{root: root} do
    provider = {InterruptedPublicProvider, self()}

    {:ok, session} =
      Elara.start_session(provider: provider, tools: [], plugins: [], cwd: root, system: "test")

    on_exit(fn -> stop_session(session) end)
    :ok = Elara.subscribe(session)
    :ok = Elara.ask_async(session, "interrupt this synthetic stream")
    assert_receive {:elara, ^session, :provider_view_changed}, 2_000
    :ok = Elara.interrupt(session)

    assert_receive {:elara, ^session,
                    {:message_appended, %Elara.Message.Assistant{interrupted: true} = partial}},
                   2_000

    assert partial.provider_state == nil
    assert [%{"text" => "Partial public summary é 👩‍💻"}] = partial.public_content
    {:ok, info} = Store.newest(root)
    stop_session(session)

    {:ok, resumed} =
      Elara.start_session(
        provider: provider,
        tools: [],
        plugins: [],
        cwd: root,
        system: "test",
        resume: info.path
      )

    on_exit(fn -> stop_session(resumed) end)
    assert List.last(Elara.transcript(resumed)) == partial
    assert JSON.encode!(Elara.materialized_view(resumed)) =~ "Partial public summary é 👩‍💻"
  end

  defp stop_session(session) do
    case Elara.session_pid(session) do
      {:ok, pid} -> if Process.alive?(pid), do: GenServer.stop(pid)
      _ -> :ok
    end
  end

  defp read_line(port, buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        {line, rest}

      [_] ->
        receive do
          {^port, {:data, data}} -> read_line(port, buffer <> data)
          {^port, {:exit_status, status}} -> flunk("fixture exited #{status}: #{buffer}")
        after
          10_000 -> flunk("fixture did not announce its HTTP port: #{buffer}")
        end
    end
  end

  defp await_exit(port, output) do
    receive do
      {^port, {:data, data}} -> await_exit(port, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      90_000 -> flunk("provider PTY did not finish: #{output}")
    end
  end
end
