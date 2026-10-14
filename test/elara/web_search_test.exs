defmodule Elara.WebSearchTest do
  use ExUnit.Case, async: false

  alias Elara.{Output, Tool, WebSearch}
  alias Elara.Auth.Exa
  alias Elara.Message.{Assistant, ToolCall, ToolResult}

  defmodule Resolver do
    def getaddrs(_, :inet), do: {:ok, [{93, 184, 216, 34}]}
    def getaddrs(_, :inet6), do: {:ok, []}
  end

  defmodule HTTP do
    def connect(_, _, _, _), do: {:ok, %{}}
    def request(conn, "GET", "/guide", _, nil), do: {:ok, conn, :page}

    def recv(conn, _, _) do
      {:ok, conn,
       [
         {:status, :page, 200},
         {:headers, :page, [{"content-type", "text/html"}]},
         {:data, :page, "<h1>Guide</h1><p>Fetched full source.</p>"},
         {:done, :page}
       ]}
    end

    def close(_), do: :ok
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    keys = [:exa_auth_path, :exa_http, :web_fetch_http, :web_fetch_resolver]
    previous = Map.new(keys, &{&1, Application.fetch_env(:elara, &1)})
    {:ok, state_root} = Elara.Session.Store.root()
    auth_root = Path.join(state_root, "exa-#{Path.basename(root)}")
    Application.put_env(:elara, :exa_auth_path, Path.join(auth_root, "exa-auth.json"))
    Application.put_env(:elara, :web_fetch_http, HTTP)
    Application.put_env(:elara, :web_fetch_resolver, Resolver)
    assert :ok = Exa.save_key("fixture-private-exa-key")

    on_exit(fn ->
      for store <- Elara.Session.Store.list(root) do
        case Elara.session_pid(store.id) do
          {:ok, pid} -> GenServer.stop(pid)
          _ -> :ok
        end
      end

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:elara, key, value)
          :error -> Application.delete_env(:elara, key)
        end
      end

      File.rm_rf!(auth_root)
    end)

    %{
      root: root,
      ctx: %Tool.Ctx{cwd: root, session_id: "search-#{System.unique_integer([:positive])}"}
    }
  end

  test "a scripted search then fetch retains receipts, excerpts and trusted web provenance", %{
    root: root
  } do
    parent = self()
    request_id = "receipt-one" <> String.duplicate("-exact", 60)
    key = ~S(fixture-"private\exa-key)
    assert :ok = Exa.save_key(key)

    Application.put_env(:elara, :exa_http, fn "https://api.exa.ai/search", opts ->
      assert opts[:headers] == [{"x-api-key", key}]

      assert opts[:json] == %{
               "query" => "Phoenix routing",
               "type" => "auto",
               "numResults" => 5,
               "contents" => %{"highlights" => true}
             }

      assert opts[:retry] == false and opts[:redirect] == false
      send(parent, :search_dispatched)

      stream(
        opts,
        200,
        JSON.encode!(%{
          "requestId" => request_id,
          "costDollars" => %{"total" => 0.005},
          "results" => [
            %{
              "title" => "Routing guide",
              "url" => "https://evidence.test/guide",
              "highlights" => ["Use verified routes. " <> String.duplicate("x", 770) <> key],
              "text" => "FULL_TEXT_NOT_REQUESTED"
            }
          ]
        })
      )
    end)

    {:ok, provider} =
      Agent.start_link(fn -> [call("web_search", %{"query" => "Phoenix routing"}), reply()] end)

    {:ok, id} =
      Elara.start_session(cwd: root, plugins: [], provider: {Elara.Provider.Scripted, provider})

    assert {:ok, "done"} = Elara.ask(id, "search")
    assert_receive :search_dispatched
    assert Elara.snapshot(id).snapshot["inbox"]["web_content_entered"] == true

    [%ToolResult{outcome: {:ok, result}}] =
      Enum.filter(Elara.transcript(id), &is_struct(&1, ToolResult))

    assert result =~ "Routing guide" and result =~ request_id and result =~ "0.005"
    assert result =~ "https://evidence.test/guide" and result =~ "Use verified routes."
    refute result =~ "FULL_TEXT_NOT_REQUESTED"
    refute result =~ "fixture-"
    [_, handle] = Regex.run(~r/\A\[output (out_[A-Za-z0-9_-]+);/, result)

    assert {:ok, retained} =
             Output.read(%Tool.Ctx{cwd: root, session_id: id}, handle, {:range, 1, 10})

    assert retained =~ request_id
    refute retained =~ "fixture-"

    Agent.update(provider, fn _ ->
      [call("web_fetch", %{"url" => "https://evidence.test/guide"}), reply()]
    end)

    assert {:ok, "done"} = Elara.ask(id, "fetch the result")

    [%ToolResult{outcome: {:ok, fetched}} | _] =
      Elara.transcript(id) |> Enum.filter(&is_struct(&1, ToolResult)) |> Enum.reverse()

    assert fetched =~ "Fetched full source."
    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(id))
    {:ok, info} = Elara.Session.Store.find(root, id)
    {:ok, store} = Elara.Session.Store.open(info.path, root)

    assert Enum.count(
             Elara.Session.Store.history(store),
             &match?(%ToolResult{name: "web_search"}, &1)
           ) == 1

    refute File.read!(store.path) =~ "fixture-"
    {:ok, pid} = Elara.session_pid(id)
    GenServer.stop(pid)
  end

  test "private login storage is fenced and absent from commands", %{ctx: ctx} do
    assert {:ok, "fixture-private-exa-key"} = Exa.load_key()
    assert {:ok, %{mode: mode}} = File.stat(Exa.auth_path())
    assert Bitwise.band(mode, 0o777) == 0o600
    assert {:error, refusal} = Elara.Tools.read(%{"path" => Exa.auth_path()}, ctx)
    assert refusal =~ "protected"
    assert {:ok, env} = Elara.Exec.Environment.command(%{})
    refute Map.has_key?(env, "EXA_API_KEY")
    assert {:error, :invalid_key} = Exa.save_key("bad\nheader")
    assert {:ok, "fixture-private-exa-key"} = Exa.load_key()
  end

  test "operator login hides typed credentials and restores terminal echo", %{root: root} do
    home = Path.join(root, "login-home")
    File.mkdir_p!(home)

    assert {output, 0} =
             System.cmd("python3", ["test/support/exa_login_pty.py"],
               env: [
                 {"HOME", home},
                 {"MIX_ENV", "test"},
                 {"MIX_HOME",
                  System.get_env("MIX_HOME") || Path.join(System.user_home!(), ".mix")},
                 {"HEX_HOME",
                  System.get_env("HEX_HOME") || Path.join(System.user_home!(), ".hex")}
               ],
               stderr_to_stdout: true
             )

    assert output =~ "hidden input and private storage passed"
  end

  test "failed evidence retains known billing, while unknown receipts are explicitly null", %{
    root: root
  } do
    Application.put_env(:elara, :exa_http, fn _, opts ->
      response =
        if opts[:json]["query"] == "billed" do
          %{
            "requestId" => "billed-invalid-row",
            "costDollars" => %{"total" => 0.007},
            "results" => [%{"url" => "not a URL"}]
          }
        else
          %{"results" => []}
        end

      stream(opts, 200, JSON.encode!(response))
    end)

    {:ok, provider} =
      Agent.start_link(fn ->
        [
          call("web_search", %{"query" => "billed"}),
          reply(),
          call("web_search", %{"query" => "unknown"}),
          reply()
        ]
      end)

    {:ok, id} =
      Elara.start_session(cwd: root, plugins: [], provider: {Elara.Provider.Scripted, provider})

    assert {:ok, "done"} = Elara.ask(id, "search rejected evidence")
    refute Elara.snapshot(id).snapshot["inbox"]["web_content_entered"]
    assert {:ok, "done"} = Elara.ask(id, "search with unknown accounting")

    [%ToolResult{outcome: {:error, failed}}, %ToolResult{outcome: {:ok, unknown}}] =
      Enum.filter(Elara.transcript(id), &is_struct(&1, ToolResult))

    assert failed =~ "invalid result URL"
    assert failed =~ "billed-invalid-row" and failed =~ "0.007"
    assert unknown =~ ~s("request_id":null)
    assert unknown =~ ~s("reported_cost_usd":null)
    {:ok, info} = Elara.Session.Store.find(root, id)
    assert File.read!(info.path) =~ "billed-invalid-row"
    {:ok, pid} = Elara.session_pid(id)
    GenServer.stop(pid)
  end

  test "a session deadline retains the unknown accounting and billing warning", %{root: root} do
    Application.put_env(:elara, :exa_http, fn _, _ -> Process.sleep(500) end)

    {:ok, provider} =
      Agent.start_link(fn -> [call("web_search", %{"query" => "deadline query"}), reply()] end)

    {:ok, id} =
      Elara.start_session(
        cwd: root,
        plugins: [],
        provider: {Elara.Provider.Scripted, provider},
        tool_timeout_ms: 30
      )

    assert {:ok, "done"} = Elara.ask(id, "search")

    [%ToolResult{outcome: {:error, preview}}] =
      Enum.filter(Elara.transcript(id), &is_struct(&1, ToolResult))

    [_, handle] = Regex.run(~r/\A\[output (out_[A-Za-z0-9_-]+);/, preview)

    assert {:ok, receipt} =
             Output.read(%Tool.Ctx{cwd: root, session_id: id}, handle, {:range, 1, 10})

    assert receipt =~ ~s("query":"deadline query")
    assert receipt =~ ~s("request_id":null)
    assert receipt =~ ~s("reported_cost_usd":null)
    assert receipt =~ "deadline exceeded; search may have been billed"
    refute Elara.snapshot(id).snapshot["inbox"]["web_content_entered"]
  end

  test "errors never echo credentials or retry, oversized responses refuse", %{ctx: ctx} do
    parent = self()

    Application.put_env(:elara, :exa_http, fn _, opts ->
      send(parent, :attempt)
      stream(opts, 401, "fixture-private-exa-key")
    end)

    assert {:error, failed} = WebSearch.run(%{"query" => "one"}, ctx)
    assert failed =~ "HTTP 401" and failed =~ "no automatic retry", failed
    assert failed =~ ~s("request_id":null)
    assert failed =~ ~s("reported_cost_usd":null)
    refute failed =~ "fixture-private-exa-key"

    assert_receive :attempt
    refute_receive :attempt

    Application.put_env(:elara, :exa_http, fn _, opts ->
      stream(opts, 200, String.duplicate("x", 1_048_577))
    end)

    assert {:error, error} = WebSearch.run(%{"query" => "too large"}, ctx)
    assert error =~ "exceeds 1 MiB"
    Application.put_env(:elara, :exa_http, fn _, _ -> Process.sleep(1000) end)
    assert {:error, deadline} = WebSearch.run(%{"query" => "slow"}, %{ctx | timeout_ms: 10})
    assert deadline =~ "deadline exceeded"
    assert deadline =~ ~s("request_id":null)
    File.rm!(Exa.auth_path())
    assert {:error, login} = WebSearch.run(%{"query" => "no login"}, ctx)
    assert login =~ "mix elara.login exa"
  end

  defp call(name, args),
    do: {:ok, %Assistant{tool_calls: [%ToolCall{id: name, name: name, args: {:ok, args}}]}}

  defp reply, do: {:ok, %Assistant{text: "done"}}

  defp stream(opts, status, bytes) do
    chunks =
      Stream.unfold(bytes, fn
        "" ->
          nil

        rest ->
          size = min(byte_size(rest), 4096)
          <<chunk::binary-size(^size), remaining::binary>> = rest
          {chunk, remaining}
      end)

    {_, response} =
      Enum.reduce_while(chunks, {Req.new(), %Req.Response{status: status, body: ""}}, fn chunk,
                                                                                         pair ->
        opts[:into].({:data, chunk}, pair)
      end)

    {:ok, response}
  end
end
