defmodule Elara.MCPTest do
  use ExUnit.Case, async: false
  alias Elara.MCP
  alias Elara.MCP.{Config, Trust}

  @fixture Path.expand("../support/mcp_server.py", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "mcp-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    cwd = Path.join(root, "workspace")
    File.mkdir_p!(Path.join(home, ".elara"))
    File.mkdir_p!(Path.join(cwd, ".elara"))
    old_home = Application.get_env(:elara, :mcp_home)
    old_trust = Application.get_env(:elara, :mcp_trust_root)
    Application.put_env(:elara, :mcp_home, home)
    Application.put_env(:elara, :mcp_trust_root, Path.join(root, "trust"))

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Elara.MCPSup),
          do: DynamicSupervisor.terminate_child(Elara.MCPSup, pid)

      if old_home,
        do: Application.put_env(:elara, :mcp_home, old_home),
        else: Application.delete_env(:elara, :mcp_home)

      if old_trust,
        do: Application.put_env(:elara, :mcp_trust_root, old_trust),
        else: Application.delete_env(:elara, :mcp_trust_root)

      File.rm_rf!(root)
    end)

    %{root: root, home: home, cwd: cwd}
  end

  for transport <- [:stdio, :http], era <- ["modern", "legacy"] do
    @transport transport
    @era era
    test "#{transport} #{@era}: lazy discovery, approval, loss, restart and changed catalog refusal",
         ctx do
      fixture = fixture(ctx.root, @transport, @era)
      put_config(ctx.cwd, %{"docs" => fixture.spec})
      assert {:error, :mcp_config_approval_required} = MCP.discover(ctx.cwd, "docs")
      refute File.exists?(Path.join(fixture.root, "requests"))
      {:ok, config} = Config.read(ctx.cwd, "docs")
      :ok = Trust.approve_config(config)
      assert {:ok, %{tools: tools}} = MCP.discover(ctx.cwd, "docs")

      assert {:ok, %{"protocol_version" => version, "server_info" => identity}} =
               MCP.diagnostics(ctx.cwd, "docs")

      assert version == if(@era == "modern", do: "2026-07-28", else: "2025-11-25")
      assert identity == %{"name" => "fixture", "version" => "1.0"}
      assert {:error, :mcp_catalog_approval_required} = MCP.call(ctx.cwd, "docs", "echo", %{})
      :ok = Trust.approve_catalog(config, tools, ["echo"])
      assert {:ok, %{read_only: ["echo"], digest: marked}} = MCP.catalog(ctx.cwd, "docs")
      :ok = Trust.approve_catalog(config, tools, [])
      assert {:ok, %{read_only: [], digest: unmarked}} = MCP.catalog(ctx.cwd, "docs")
      refute marked == unmarked
      :ok = Trust.approve_catalog(config, tools, ["echo"])

      assert {:ok, %{"content" => [%{"text" => "echo ✓"}], "structuredContent" => info}} =
               MCP.call(ctx.cwd, "docs", "echo", %{"region" => "日本"})

      if @era == "modern",
        do:
          assert(
            info["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
          )

      if @transport == :http do
        assert info["headers"]["mcp-name"] == "echo"
        assert info["headers"]["mcp-method"] == "tools/call"

        assert info["headers"]["mcp-protocol-version"] ==
                 if(@era == "modern", do: "2026-07-28", else: "2025-11-25")

        assert info["headers"]["mcp-param-region"] == "=?base64?5pel5pys?="
        if @era == "legacy", do: assert(info["headers"]["mcp-session-id"] == "fixture-session")
      end

      assert {:indeterminate, _} = MCP.call(ctx.cwd, "docs", "lost", %{})
      changed_era = if @era == "modern", do: "legacy", else: "modern"
      File.write!(Path.join(fixture.root, "era.txt"), changed_era)

      File.write!(
        Path.join(fixture.root, "identity.json"),
        ~s({"name":"fixture","version":"2.0"})
      )

      assert {:ok, _} = MCP.call(ctx.cwd, "docs", "echo", %{})

      assert {:ok, %{"protocol_version" => changed_version, "server_info" => changed_identity}} =
               MCP.diagnostics(ctx.cwd, "docs")

      assert changed_version == if(changed_era == "modern", do: "2026-07-28", else: "2025-11-25")
      assert changed_identity == %{"name" => "fixture", "version" => "2.0"}
      assert File.read!(Path.join(fixture.root, "calls")) == "echo\nlost\necho\n"
      [first | rest] = tools

      File.write!(
        Path.join(fixture.root, "catalog.json"),
        JSON.encode!([Map.put(first, "description", "changed authority") | rest])
      )

      assert {:error, :mcp_catalog_approval_required} = MCP.call(ctx.cwd, "docs", "echo", %{})
      assert File.read!(Path.join(fixture.root, "calls")) == "echo\nlost\necho\n"
      project = Path.join(ctx.cwd, ".elara/mcp.json")

      {:ok, _} =
        Elara.Tools.write(
          %{"path" => project, "content" => File.read!(project) <> "\n"},
          %Elara.Tool.Ctx{cwd: ctx.cwd}
        )

      assert {:error, :mcp_config_approval_required} = MCP.call(ctx.cwd, "docs", "echo", %{})
    end
  end

  test "user servers add to project servers; a clash names both sources", ctx do
    user = fixture(ctx.root, :stdio, "modern")
    put_config(ctx.home, %{"personal" => user.spec})
    put_config(ctx.cwd, %{"project" => user.spec})
    assert {:ok, personal} = Config.read(ctx.cwd, "personal")
    assert personal.path == Path.join(ctx.home, ".elara/mcp.json")
    assert {:ok, _} = Config.read(ctx.cwd, "project")
    file_ctx = %Elara.Tool.Ctx{cwd: ctx.home}

    assert {:error, "file access refused: protected_path"} =
             Elara.Tools.read(%{"path" => personal.path}, file_ctx)

    File.ln_s!(personal.path, Path.join(ctx.cwd, "innocent.json"))

    assert {:error, "file access refused: protected_path"} =
             Elara.Tools.read(%{"path" => "innocent.json"}, %Elara.Tool.Ctx{cwd: ctx.cwd})

    put_config(ctx.cwd, %{"personal" => user.spec})
    assert {:error, reason} = Config.read(ctx.cwd, "personal")
    assert reason =~ Path.join(ctx.home, ".elara/mcp.json")
    assert reason =~ Path.join(ctx.cwd, ".elara/mcp.json")
  end

  test "stdio receives only its referenced token, not unrelated VM credentials", ctx do
    fixture = fixture(ctx.root, :stdio, "modern")
    System.put_env("ELARA_TEST_MCP_SERVER", "fixture-only")
    System.put_env("ELARA_TEST_MCP_UNRELATED", "must-not-forward")

    on_exit(fn ->
      System.delete_env("ELARA_TEST_MCP_SERVER")
      System.delete_env("ELARA_TEST_MCP_UNRELATED")
    end)

    spec = Map.put(fixture.spec, "env", %{"SERVER_TOKEN" => "ELARA_TEST_MCP_SERVER"})
    put_config(ctx.cwd, %{"private" => spec})
    approve(ctx.cwd, "private")
    assert {:ok, %{"structuredContent" => info}} = MCP.call(ctx.cwd, "private", "echo", %{})
    assert info["server_token_present"]
    refute info["unrelated_token_present"]
  end

  test "HTTP sends only its referenced bearer token", ctx do
    fixture = fixture(ctx.root, :http, "modern")
    File.write!(Path.join(fixture.root, "expected-token"), "fixture-only")
    System.put_env("ELARA_TEST_MCP_SERVER", "fixture-only")
    on_exit(fn -> System.delete_env("ELARA_TEST_MCP_SERVER") end)

    put_config(ctx.cwd, %{
      "private" => Map.put(fixture.spec, "token_env", "ELARA_TEST_MCP_SERVER")
    })

    approve(ctx.cwd, "private")
    assert {:ok, _} = MCP.call(ctx.cwd, "private", "echo", %{})
    System.put_env("ELARA_TEST_MCP_SERVER", "wrong-token")
    assert {:indeterminate, :bad_http_status} = MCP.call(ctx.cwd, "private", "echo", %{})
    assert File.read!(Path.join(fixture.root, "calls")) == "echo\n"
  end

  test "HTTP approval never silently excludes unsupported tool definitions", ctx do
    fixture = fixture(ctx.root, :http, "modern")
    put_config(ctx.cwd, %{"full" => fixture.spec})
    approve(ctx.cwd, "full")
    original = File.read!(Path.join(fixture.root, "catalog.json"))
    tools = JSON.decode!(original)

    unsupported = %{
      "name" => "hidden",
      "description" => "first",
      "inputSchema" => %{
        "oneOf" => [
          %{
            "type" => "object",
            "properties" => %{"region" => %{"type" => "string", "x-mcp-header" => "Region"}}
          }
        ]
      }
    }

    for description <- ["first", "changed without approval"] do
      File.write!(
        Path.join(fixture.root, "catalog.json"),
        JSON.encode!(tools ++ [Map.put(unsupported, "description", description)])
      )

      assert {:error, :invalid_catalog_header_annotation} = MCP.discover(ctx.cwd, "full")
      assert {:error, :invalid_catalog_header_annotation} = MCP.call(ctx.cwd, "full", "echo", %{})
      refute File.exists?(Path.join(fixture.root, "calls"))
    end

    supported = Map.put(unsupported, "inputSchema", %{"type" => "object"})
    File.write!(Path.join(fixture.root, "catalog.json"), JSON.encode!(tools ++ [supported]))
    assert {:error, :mcp_catalog_approval_required} = MCP.call(ctx.cwd, "full", "echo", %{})
    refute File.exists?(Path.join(fixture.root, "calls"))
    File.write!(Path.join(fixture.root, "catalog.json"), original)
    assert {:ok, _} = MCP.call(ctx.cwd, "full", "echo", %{})
    assert File.read!(Path.join(fixture.root, "calls")) == "echo\n"
  end

  for transport <- [:stdio, :http] do
    @transport transport
    test "#{transport}: timeout, byte cap and unsupported input do not claim success or replay",
         ctx do
      fixture = fixture(ctx.root, @transport, "modern")
      put_config(ctx.cwd, %{"bounded" => fixture.spec})
      approve(ctx.cwd, "bounded")
      assert {:indeterminate, _} = MCP.call(ctx.cwd, "bounded", "slow", %{}, timeout_ms: 500)
      assert {:ok, _} = MCP.call(ctx.cwd, "bounded", "echo", %{})

      below = 16_777_216 - 1024

      assert {:ok, %{"content" => [%{"text" => text}]}} =
               MCP.call(ctx.cwd, "bounded", "flood", %{"bytes" => below})

      assert text == String.duplicate("x", below)

      assert {:indeterminate, "result too large:" <> reason} =
               MCP.call(ctx.cwd, "bounded", "flood", %{})

      assert reason =~ "limit 16 MiB"

      {:ok, config} = Config.read(ctx.cwd, "bounded")
      {:ok, %{tools: tools}} = MCP.discover(ctx.cwd, "bounded")
      :ok = Trust.approve_catalog(config, tools, ["flood"])
      assert {:error, "result too large:" <> _} = MCP.call(ctx.cwd, "bounded", "flood", %{})
      assert {:ok, _} = MCP.call(ctx.cwd, "bounded", "echo", %{})

      assert {:indeterminate, :unsupported_input_required} =
               MCP.call(ctx.cwd, "bounded", "input", %{})

      assert File.read!(Path.join(fixture.root, "calls")) ==
               "slow\necho\nflood\nflood\nflood\necho\ninput\n"
    end
  end

  for transport <- [:stdio, :http] do
    @transport transport
    test "#{transport} supervised connection restarts after a crash without replaying a call",
         ctx do
      fixture = fixture(ctx.root, @transport, "modern")
      put_config(ctx.cwd, %{"supervised" => fixture.spec})
      approve(ctx.cwd, "supervised")
      task = Task.async(fn -> MCP.call(ctx.cwd, "supervised", "slow", %{}) end)
      wait_for(fn -> File.exists?(Path.join(fixture.root, "calls")) end)
      {:ok, config} = Config.read(ctx.cwd, "supervised")
      [{pid, _}] = Registry.lookup(Elara.MCPRegistry, {config.path, config.name})
      Process.exit(pid, :kill)
      assert {:indeterminate, _} = Task.await(task)

      wait_for(fn ->
        case Registry.lookup(Elara.MCPRegistry, {config.path, config.name}) do
          [{new, _}] -> new != pid
          _ -> false
        end
      end)

      assert {:ok, _} = MCP.call(ctx.cwd, "supervised", "echo", %{})
      assert File.read!(Path.join(fixture.root, "calls")) == "slow\necho\n"
    end
  end

  test "expired queued requests never dispatch a tool call", ctx do
    fixture = fixture(ctx.root, :stdio, "modern")
    put_config(ctx.cwd, %{"serial" => fixture.spec})
    approve(ctx.cwd, "serial")
    first = Task.async(fn -> MCP.call(ctx.cwd, "serial", "slow", %{}) end)
    wait_for(fn -> File.exists?(Path.join(fixture.root, "calls")) end)
    expired = Task.async(fn -> MCP.call(ctx.cwd, "serial", "echo", %{}, timeout_ms: 20) end)
    assert {:indeterminate, :mcp_timeout} = Task.await(expired, 1000)
    assert {:ok, _} = Task.await(first)
    assert File.read!(Path.join(fixture.root, "calls")) == "slow\n"
  end

  for transport <- [:stdio, :http] do
    @transport transport
    test "#{transport}: config edited during catalog retrieval refuses before tool dispatch",
         ctx do
      fixture = fixture(ctx.root, @transport, "modern")
      put_config(ctx.cwd, %{"guarded" => fixture.spec})
      approve(ctx.cwd, "guarded")
      project = Path.join(ctx.cwd, ".elara/mcp.json")
      original = File.read!(project)
      hold = Path.join(fixture.root, "hold-list")
      File.touch!(hold)
      call = Task.async(fn -> MCP.call(ctx.cwd, "guarded", "echo", %{}) end)
      wait_for(fn -> File.exists?(Path.join(fixture.root, "list-waiting")) end)
      File.write!(project, original <> "\n")
      File.rm!(hold)
      assert {:error, :mcp_config_changed} = Task.await(call)
      refute File.exists?(Path.join(fixture.root, "calls"))
      File.write!(project, original)
      assert {:ok, _} = MCP.call(ctx.cwd, "guarded", "echo", %{})
      assert File.read!(Path.join(fixture.root, "calls")) == "echo\n"
    end
  end

  test "catalog allows a terminating page 100 but never requests page 101", ctx do
    for pages <- [100, 101] do
      fixture = fixture(ctx.root, :stdio, "modern")
      File.write!(Path.join(fixture.root, "pages"), Integer.to_string(pages))
      put_config(ctx.cwd, %{"pages" => fixture.spec})
      {:ok, config} = Config.read(ctx.cwd, "pages")
      :ok = Trust.approve_config(config)
      result = MCP.discover(ctx.cwd, "pages")

      if pages == 100 do
        assert {:ok, %{tools: tools}} = result
        assert Enum.map(tools, & &1["name"]) == ~w(echo flood input lost slow)
      else
        assert {:error, :catalog_too_large} = result
      end

      requested = File.read!(Path.join(fixture.root, "requests")) |> String.split("\n")
      assert Enum.count(requested, &(&1 == "tools/list")) == 100
    end
  end

  defp approve(cwd, name) do
    {:ok, config} = Config.read(cwd, name)
    :ok = Trust.approve_config(config)
    {:ok, %{tools: tools}} = MCP.discover(cwd, name)
    :ok = Trust.approve_catalog(config, tools, [])
  end

  defp put_config(base, servers),
    do:
      File.write!(
        Path.join(base, ".elara/mcp.json"),
        JSON.encode!(%{"servers" => servers})
      )

  defp fixture(root, transport, era) do
    root = Path.join(root, "fixture-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    schema = %{
      "type" => "object",
      "properties" => %{"region" => %{"type" => "string", "x-mcp-header" => "Region"}}
    }

    tools =
      Enum.map(~w(echo lost slow flood input), fn name ->
        %{"name" => name, "description" => name, "inputSchema" => schema}
      end)

    File.write!(Path.join(root, "catalog.json"), JSON.encode!(tools))
    python = System.find_executable("python3")

    spec =
      case transport do
        :stdio ->
          %{"transport" => "stdio", "command" => python, "args" => [@fixture, root, era]}

        :http ->
          port =
            Port.open({:spawn_executable, python}, [
              :binary,
              :exit_status,
              args: [@fixture, root, era, "--http"]
            ])

          number =
            receive do
              {^port, {:data, bytes}} -> bytes |> String.trim() |> String.to_integer()
            after
              5000 -> flunk("HTTP fixture did not start")
            end

          {:os_pid, pid} = Port.info(port, :os_pid)

          on_exit(fn ->
            System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
          end)

          %{"transport" => "http", "url" => "http://127.0.0.1:#{number}/mcp"}
      end

    %{root: root, spec: spec}
  end

  defp wait_for(predicate, attempts \\ 100)
  defp wait_for(_predicate, 0), do: flunk("condition did not settle")

  defp wait_for(predicate, attempts) do
    if predicate.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_for(predicate, attempts - 1)
        )
  end
end
