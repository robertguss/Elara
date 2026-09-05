defmodule Elara.InputAttachmentsProductTest do
  use ExUnit.Case, async: false

  @tag timeout: 120_000
  test "selected files and disk images reach HTTP and survive source changes and resume" do
    root =
      Path.join(System.tmp_dir!(), "elara-input-product-#{System.unique_integer([:positive])}")

    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)
    File.write!(Path.join(cwd, "notes α file.txt"), "BEFORE_SELECTION")
    previous = Application.get_env(:elara, :sessions_root)
    Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:elara, :sessions_root, previous),
        else: Application.delete_env(:elara, :sessions_root)

      File.rm_rf!(root)
    end)

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
          args: [Path.expand("../support/input_attachments_pty.py", __DIR__), binary, root],
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
    assert {:ok, %{"http_port" => port}} = JSON.decode(line)

    tokens = %Elara.Auth.OpenAICodex{
      access_token: "input-product-access-canary",
      refresh_token: "input-product-refresh-canary",
      account_id: "test-account",
      expires_at: System.system_time(:second) + 3_600
    }

    provider =
      {Elara.Provider.OpenAICodex,
       Elara.Provider.OpenAICodex.new(tokens, base_url: "http://127.0.0.1:#{port}/backend-api")}

    {:ok, session} =
      Elara.start_session(provider: provider, tools: [], plugins: [], cwd: cwd, system: "test")

    on_exit(fn -> stop_session(session) end)
    {:ok, server} = Elara.Server.start_link(port: 0, provider: provider)

    Port.command(
      child,
      JSON.encode!(%{session: session, port: Elara.Server.port(server)}) <> "\n"
    )

    {line, buffered} = read_line(child, buffered)

    unless JSON.decode(line) == {:ok, %{"phase" => "terminal_done"}} do
      {output, _status} = await_exit(child, line <> "\n" <> buffered)
      flunk(output)
    end

    [user | _] = Elara.transcript(session)
    assert user.text == "Analyze é 👩‍💻 sent"
    assert [%{"kind" => "text"} = text, %{"kind" => "image"} = image] = user.attachments
    assert text["content"] == "AT_SUBMISSION"
    assert image["name"] == "outside blue yellow α.png"
    assert image["mime_type"] == "image/png"
    assert Base.decode64!(image["base64"]) == File.read!(Path.join(root, "expected.png"))

    view = Elara.materialized_view(session)
    refute JSON.encode!(view) =~ image["base64"]
    File.rm!(Path.join(cwd, "notes α file.txt"))
    {:ok, info} = Elara.Session.Store.newest(cwd)
    stop_session(session)

    {:ok, resumed} =
      Elara.start_session(
        provider: provider,
        tools: [],
        plugins: [],
        cwd: cwd,
        system: "test",
        resume: info.path
      )

    on_exit(fn -> stop_session(resumed) end)
    assert hd(Elara.transcript(resumed)) == user
    assert {:ok, "INPUT_ATTACHMENT_DONE"} = Elara.ask(resumed, "Recall the selected inputs")
    Port.command(child, "finish\n")
    {output, status} = await_exit(child, buffered)
    assert status == 0, output
    assert output =~ "Input attachment PTY passed"
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
          60_000 -> flunk("fixture did not reach its next phase: #{buffer}")
        end
    end
  end

  defp await_exit(port, output) do
    receive do
      {^port, {:data, data}} -> await_exit(port, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      10_000 -> flunk("fixture did not exit: #{output}")
    end
  end
end
