defmodule Elara.GatewayTrustTest do
  use ExUnit.Case, async: false

  alias Elara.Plugin.{Loader, Trust}
  alias Elara.Protocol

  @token String.duplicate("gateway-fixture-", 3)

  setup do
    cwd = Path.join(System.tmp_dir!(), "gateway-trust-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)

    on_exit(fn ->
      for session <- Elara.live_sessions(), Elara.Session.Store.same_cwd?(session.cwd, cwd) do
        {:ok, pid} = Elara.session_pid(session.id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end

      File.rm_rf!(cwd)
    end)

    %{cwd: cwd}
  end

  defp server(token) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    {:ok, server} =
      Elara.Server.start(port: 0, token: token, provider: {Elara.Provider.Scripted, agent})

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    server
  end

  defp request(server, request) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Elara.Server.port(server), [
        :binary,
        packet: :line,
        active: false
      ])

    on_exit(fn -> :gen_tcp.close(socket) end)
    :ok = :gen_tcp.send(socket, Protocol.encode(request))
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    {:ok, response} = Protocol.decode(line)
    :gen_tcp.close(socket)
    response
  end

  test "authentication precedes first-request operations including rejected legacy versions", %{
    cwd: cwd
  } do
    server = server(@token)
    before = Elara.live_sessions() |> Enum.map(& &1.id) |> Enum.sort()

    for version <- [1, 2],
        command <- ~w(create attach list),
        token <- [
          nil,
          "wrong",
          false,
          %{},
          @token <> "x",
          String.duplicate("x", byte_size(@token))
        ] do
      request = %{
        "version" => version,
        "command" => command,
        "cwd" => cwd,
        "session_id" => "missing"
      }

      request = if token == nil, do: request, else: Map.put(request, "token", token)
      response = request(server, request)
      assert response["type"] == "error"
      assert response["error"] == "authentication_failed"
      refute IO.iodata_to_binary(Protocol.encode(response)) =~ @token
    end

    assert Elara.live_sessions() |> Enum.map(& &1.id) |> Enum.sort() == before

    assert %{"error" => "unsupported_version"} =
             request(server, %{
               "version" => 1,
               "command" => "create",
               "cwd" => cwd,
               "token" => @token
             })

    assert %{"type" => "sessions"} =
             request(server, %{
               "version" => 2,
               "command" => "list",
               "cwd" => cwd,
               "token" => @token
             })

    assert %{"type" => "attached", "session_id" => id} =
             request(server, %{
               "version" => 2,
               "command" => "create",
               "cwd" => cwd,
               "token" => @token
             })

    {:ok, pid} = Elara.session_pid(id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
  end

  test "invalid configured credentials prevent the listener from starting" do
    for token <- [
          nil,
          "",
          false,
          1,
          String.duplicate("x", 31),
          String.duplicate("x", 513),
          :binary.copy(<<255>>, 32)
        ] do
      result = Elara.Server.start(port: 0, token: token)

      on_exit(fn ->
        case result do
          {:ok, pid} -> if Process.alive?(pid), do: GenServer.stop(pid)
          _ -> :ok
        end
      end)

      assert result == {:error, :server_token_required}
    end
  end

  test "unapproved and changed plugin bytes cannot execute during compilation", %{cwd: cwd} do
    {path, witness, source} = write_fixture(cwd)
    result = Loader.load(path)
    refute File.exists?(witness)
    assert result == {:error, :plugin_trust_required}
    assert {:ok, snapshot} = Trust.snapshot([path])
    assert :ok = Trust.approve(snapshot)
    assert {:ok, _candidate} = Loader.load(path)
    assert File.read!(witness) == "original"
    changed = String.replace(source, "\"original\"", "\"changed\"")
    File.write!(path, changed)
    assert {:error, :plugin_trust_required} = Loader.load(path)
    assert File.read!(witness) == "original"
    # Approving the earlier snapshot cannot approve a concurrent source edit.
    assert :ok = Trust.approve(snapshot)
    assert {:error, :plugin_trust_required} = Loader.load(path)
    assert {:ok, revised} = Trust.snapshot([path])
    assert :ok = Trust.approve(revised)
    assert {:ok, _candidate} = Loader.load(path)
    assert File.read!(witness) == "changed"
  end

  test "explicit workspace trust rejects default, decline and EOF before accepting", %{cwd: cwd} do
    {path, witness, _source} = write_fixture(cwd)

    for answer <- ["n\n", "\n", ""] do
      output = ExUnit.CaptureIO.capture_io(answer, fn -> Mix.Tasks.Elara.Trust.run([cwd]) end)
      assert output =~ "No plugin approval saved."
      assert output =~ "full OS-user authority"
      assert {:error, :plugin_trust_required} = Loader.load(path)
      refute File.exists?(witness)
    end

    output = ExUnit.CaptureIO.capture_io("yes\n", fn -> Mix.Tasks.Elara.Trust.run([cwd]) end)
    assert output =~ "Approved."
    assert {:ok, _candidate} = Loader.load(path)
    assert File.read!(witness) == "original"
    root = Application.fetch_env!(:elara, :plugin_trust_root)
    assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o700

    for file <- Path.wildcard(Path.join(root, "*.sha256")),
        do: assert(Bitwise.band(File.stat!(file).mode, 0o777) == 0o600)
  end

  @tag timeout: 30_000
  test "actual native client authenticates new, list and repeated attachments without exposing the token",
       %{cwd: cwd} do
    server = server(@token)
    binary = Mix.Tasks.Elara.Tui.binary!()

    options = [
      cd: cwd,
      env: [{"ELARA_SERVER_TOKEN", @token}, {"ELARA_TUI_STATE_DIR", Path.join(cwd, "client")}],
      stderr_to_stdout: true
    ]

    base = ["--headless", "--port", Integer.to_string(Elara.Server.port(server))]
    {created, 0} = System.cmd(binary, base ++ ["--", "new"], options)
    [session] = Enum.filter(Elara.live_sessions(), &Elara.Session.Store.same_cwd?(&1.cwd, cwd))
    {:ok, pid} = Elara.session_pid(session.id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    refute created =~ @token

    for target <- ["list", session.id, session.id] do
      {output, 0} = System.cmd(binary, base ++ ["--", target], options)
      assert output =~ session.id
      refute output =~ @token
    end

    driver = Path.expand("../support/gateway_reconnect_pty.py", __DIR__)

    {reconnected, 0} =
      System.cmd(
        "python3",
        [driver, binary, Integer.to_string(Elara.Server.port(server))],
        options
      )

    assert reconnected =~ "Reconnect auth passed"
    assert reconnected =~ ~s("proxy_thread_stopped": true)
    assert reconnected =~ ~s("peer_sockets_closed": true)
    IO.puts(reconnected)

    {failed, status} =
      System.cmd(
        "python3",
        [driver, binary, Integer.to_string(Elara.Server.port(server)), "force-failure"],
        options
      )

    assert status != 0
    assert failed =~ "forced failure after authenticated reconnect"
    assert failed =~ ~s("native_stopped": true)
    assert failed =~ ~s("proxy_thread_stopped": true)
    assert failed =~ ~s("listener_closed": true)
    assert failed =~ ~s("peer_sockets_closed": true)
    IO.puts(Enum.find(String.split(failed, "\n"), &String.starts_with?(&1, "cleanup=")))

    wrong =
      Keyword.put(options, :env, [
        {"ELARA_SERVER_TOKEN", String.duplicate("x", byte_size(@token))},
        {"ELARA_TUI_STATE_DIR", Path.join(cwd, "client")}
      ])

    {output, status} = System.cmd(binary, base ++ ["--", "list"], wrong)
    assert status != 0
    assert output =~ "authentication_failed"
    refute output =~ @token
  end

  defp write_fixture(cwd) do
    path = Path.join(cwd, ".elara/plugins/plugin.exs")
    witness = Path.join(cwd, "compiled")
    module = "TrustFixture#{System.unique_integer([:positive])}"

    source = """
    defmodule #{module} do
      File.write!(#{inspect(witness)}, "original")
      def metadata, do: %{id: "trust-fixture", version: "1"}
      def tools, do: []
      def init(_ctx), do: {:ok, nil}
      def handle_tool(_name, _args, _ctx, state), do: {{:ok, "ok"}, state}
    end
    """

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    {path, witness, source}
  end
end
