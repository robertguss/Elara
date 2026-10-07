defmodule Elara.LauncherTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @root Path.expand("../..", __DIR__)
  @launcher Path.join(@root, "bin/elara")

  setup %{tmp_dir: tmp} do
    caller = Path.join(tmp, "caller project")
    target = Path.join(caller, "selected workspace")
    home = Path.join(tmp, "home")
    for dir <- [target, home], do: File.mkdir_p!(dir)

    # Subprocesses use dev so test runtime config doesn't erase the environment
    # whose forwarding we're checking. Never inherit real provider credentials.
    env =
      for {key, _} <- System.get_env(),
          String.starts_with?(key, "ELARA_") or
            key in ["XAI_API_KEY", "CODEX_HOME", "MIX_EXS", "MIX_BUILD_PATH", "MIX_BUILD_ROOT"],
          into: %{},
          do: {key, nil}

    env =
      Map.merge(env, %{
        "HOME" => home,
        "MIX_HOME" => Mix.Utils.mix_home(),
        "HEX_HOME" => System.get_env("HEX_HOME", Path.expand("~/.hex")),
        "RUSTUP_HOME" => System.get_env("RUSTUP_HOME", Path.expand("~/.rustup")),
        "CARGO_HOME" => System.get_env("CARGO_HOME", Path.expand("~/.cargo")),
        "MIX_ENV" => "dev",
        "ELARA_API_KEY" => "offline-launcher-test-key",
        "ELARA_SERVER_TOKEN" => System.fetch_env!("ELARA_SERVER_TOKEN"),
        "ELARA_TUI_STATE_DIR" => "ui state",
        "ELARA_TUI_APPEARANCE_FILE" => "appearance.json"
      })

    existing = MapSet.new(Elara.live_sessions(), & &1.id)

    on_exit(fn ->
      for session <- Elara.live_sessions(), not MapSet.member?(existing, session.id) do
        {:ok, pid} = Elara.session_pid(session.id)
        DynamicSupervisor.terminate_child(Elara.SessionSup, pid)
      end
    end)

    %{caller: caller, target: target, home: home, env: env}
  end

  defp launch(ctx, args, extra_env \\ %{}) do
    System.cmd(@launcher, args,
      cd: ctx.caller,
      env: Map.merge(ctx.env, extra_env),
      stderr_to_stdout: true
    )
  end

  defp available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    Integer.to_string(port)
  end

  defp frames(output) do
    Regex.scan(~r/event_ms=[\d.]+ frame=(.+)/, output, capture: :all_but_first)
    |> Enum.map(fn [json] -> :json.decode(json) end)
  end

  defp attached(output) do
    Enum.find(frames(output), &(&1["type"] == "attached")) || flunk(output)
  end

  defp assistant(text) do
    {:ok, message} = Elara.Message.assistant(text, [])
    message
  end

  test "wrapper preserves argv and exit status without leaking MIX_EXS into tools", ctx do
    mock_bin = Path.join(ctx.caller, "mock bin")
    File.mkdir_p!(mock_bin)
    mix = Path.join(mock_bin, "mix")

    File.write!(mix, """
    #!/bin/sh
    [ -z "${MIX_EXS+x}" ] || exit 91
    printf '%s\\000' "$PWD" "$@"
    exit 17
    """)

    File.chmod!(mix, 0o755)
    args = ["--ask", "a prompt\nwith spaces", "--", "-session"]

    assert {output, 17} =
             launch(ctx, args, %{
               "PATH" => mock_bin <> ":" <> System.fetch_env!("PATH"),
               "MIX_EXS" => "/another/project/mix.exs"
             })

    assert String.split(output, <<0>>, trim: true) ==
             [@root, "elara.launch", ctx.caller | args]
  end

  test "launcher uses its own project, builds there, and saves/reopens in caller cwd", ctx do
    # Neither the caller's Mix project nor its runtime config may be evaluated.
    File.write!(Path.join(ctx.caller, "mix.exs"), ~s(raise "WRONG PROJECT"))
    File.mkdir_p!(Path.join(ctx.caller, "config"))
    File.write!(Path.join(ctx.caller, "config/runtime.exs"), ~s(raise "WRONG CONFIG"))
    # Force the native installation path, not merely a warm-cache invocation.
    digest = Path.join(@root, "_build/dev/lib/elara/priv/native/elara-tui.sha256")
    File.rm(digest)
    port = available_port()
    args = ["--headless", "--event-dump", "--port", port]
    assert {output, 0} = launch(ctx, args, %{"MIX_EXS" => Path.join(ctx.caller, "mix.exs")})
    first = attached(output)
    id = first["session_id"]
    assert is_binary(id)
    assert File.regular?(digest)
    refute File.exists?(Path.join(ctx.caller, "_build"))
    refute File.exists?(Path.join(ctx.caller, "deps"))
    assert File.regular?(Path.join(ctx.caller, "ui state/cursors.json"))

    assert {listing, 0} = launch(ctx, ["--port", port, "list"])
    assert listing =~ "#{id}\tsaved\t0\t#{ctx.caller}"
    assert {reopened, 0} = launch(ctx, args ++ ["--", id])
    assert attached(reopened)["session_id"] == id
    assert {listing, 0} = launch(ctx, ["--port", port, "list"])
    assert listing =~ "#{id}\tsaved\t0\t#{ctx.caller}"
    # The embedded server exits with the launcher, freeing the selected port.
    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, String.to_integer(port), [], 500)
  end

  test "relative workspace, credentials and UI paths keep distinct bases", ctx do
    codex = Path.join(ctx.caller, "codex credentials")
    File.mkdir_p!(codex)

    payload =
      :json.encode(%{"exp" => System.system_time(:second) + 3600}) |> IO.iodata_to_binary()

    fake_jwt = "fake." <> Base.url_encode64(payload, padding: false) <> ".signature"

    auth =
      :json.encode(%{"tokens" => %{"access_token" => fake_jwt, "account_id" => "test-account"}})

    File.write!(Path.join(codex, "auth.json"), auth)
    File.write!(Path.join(ctx.caller, "appearance.json"), "invalid-json-from-caller")

    assert {output, 0} =
             launch(
               ctx,
               [
                 "--cwd",
                 ".",
                 "--cwd",
                 "selected workspace",
                 "--headless",
                 "--event-dump",
                 "--port",
                 available_port()
               ],
               %{
                 "ELARA_API_KEY" => nil,
                 "ELARA_PROVIDER" => "openai-codex",
                 "ELARA_CODEX_AUTH_SOURCE" => "codex",
                 "CODEX_HOME" => "codex credentials",
                 "ELARA_MODEL" => "gpt-5.5",
                 "ELARA_REASONING_EFFORT" => "high"
               }
             )

    snapshot = attached(output)["snapshot"]

    assert snapshot["provider_view"]["next_request"] == %{
             "model" => "gpt-5.5",
             "effort" => "high"
           }

    assert output =~ "Invalid appearance preferences"
    assert File.regular?(Path.join(ctx.caller, "ui state/cursors.json"))
    refute File.exists?(Path.join(ctx.target, "ui state"))
    assert File.read!(Path.join(codex, "auth.json")) == IO.iodata_to_binary(auth)
    saved = Path.wildcard(Path.join(ctx.home, ".elara/sessions/*/*.jsonl"))
    assert length(saved) == 1
    header = hd(saved) |> File.stream!() |> Enum.take(1) |> hd() |> :json.decode()
    assert header["cwd"] == ctx.target
  end

  test "native grammar preserves prompts and explicit live-session authority", ctx do
    {:ok, agent} =
      Agent.start_link(fn ->
        [{:ok, assistant("literal accepted")}, {:ok, assistant("second accepted")}]
      end)

    provider = {Elara.Provider.Scripted, agent}
    {:ok, server} = Elara.Server.start_link(port: 0, provider: provider)
    port = Integer.to_string(Elara.Server.port(server))
    args = ["--headless", "--event-dump", "--port", "1", "--port", port]
    assert {first, 0} = launch(ctx, args ++ ["--ask", "--cwd"])
    id = attached(first)["session_id"]
    assert {:ok, pid} = Elara.session_pid(id)
    assert Enum.any?(Elara.transcript(pid), &match?(%Elara.Message.User{text: "--cwd"}, &1))

    assert {second, 0} =
             launch(ctx, args ++ ["--cwd", "selected workspace", "--ask", "--", "--", id])

    assert attached(second)["session_id"] == id
    assert Elara.cwd(pid) == ctx.caller
    assert Enum.any?(Elara.transcript(pid), &match?(%Elara.Message.User{text: "--"}, &1))
    assert Process.alive?(server)
  end

  test "bad arguments fail before attachment instead of consuming the default target", ctx do
    for {args, message} <- [
          {["--ask"], "--ask requires a value"},
          {["--cwd"], "--cwd requires a value"},
          {["--cwd", "missing"], "--cwd must name an existing directory"},
          {["--unknown"], "unknown option --unknown"},
          {["--", "-literal-session"], "session_not_found"}
        ] do
      assert {output, 1} = launch(ctx, ["--port", available_port()] ++ args)
      assert output =~ message
    end

    refute File.exists?(Path.join(ctx.caller, "ui state/cursors.json"))
  end

  test "launcher retains interactive terminal input and clean detach", ctx do
    replies =
      List.duplicate({:stream, ["working", {:sleep, 5_000}], {:ok, assistant("complete")}}, 3)

    {:ok, agent} = Agent.start_link(fn -> replies end)

    {:ok, session} =
      Elara.start_session(
        provider: {Elara.Provider.Scripted, agent},
        tools: [],
        persist: false,
        cwd: ctx.caller
      )

    {:ok, server} = Elara.Server.start_link(port: 0)
    python = System.find_executable("python3") || flunk("python3 is required for PTY checks")

    {output, status} =
      System.cmd(
        python,
        [
          Path.join(@root, "test/support/tui_pty.py"),
          @launcher,
          Integer.to_string(Elara.Server.port(server)),
          session,
          "ctrl-c"
        ],
        cd: ctx.caller,
        env: ctx.env,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "PTY passed"
    assert Process.alive?(server)
  end
end
