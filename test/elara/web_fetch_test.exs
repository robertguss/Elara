defmodule Elara.WebFetchTest do
  use ExUnit.Case, async: false

  alias Elara.Message.{Assistant, ToolCall, ToolResult}
  alias Elara.{Output, Tool, WebFetch}

  defmodule Resolver do
    def getaddrs(_, family) do
      {:ok, Application.fetch_env!(:elara, :web_fetch_fixture).addresses[family]}
    end
  end

  defmodule HTTP do
    def connect(_, address, _, _) do
      fixture = Application.fetch_env!(:elara, :web_fetch_fixture)
      send(fixture.parent, {:connected, address})
      {:ok, %{fixture: fixture}}
    end

    def request(conn, "GET", path, headers, nil) do
      send(conn.fixture.parent, {:get, path, headers})
      {status, response_headers, body} = Map.fetch!(conn.fixture.pages, path)
      {:ok, Map.merge(conn, %{response: {status, response_headers, body}}), :page}
    end

    def recv(conn, _, _) do
      if conn.fixture[:block] do
        send(conn.fixture.parent, {:fetch_worker, self()})
        Process.sleep(:infinity)
      end

      {status, headers, body} = conn.response

      {:ok, conn,
       Map.get(conn.fixture, :informational, []) ++
         [
           {:status, :page, status},
           {:headers, :page, headers},
           {:data, :page, body},
           {:done, :page}
         ]}
    end

    def close(_), do: :ok
  end

  defmodule Forged do
    def run(_, _), do: {:ok, "[Untrusted web content] web content in context"}
  end

  setup do
    keys = [:web_fetch_resolver, :web_fetch_http, :web_fetch_fixture]
    old = Map.new(keys, &{&1, Application.fetch_env(:elara, &1)})
    root = Path.join(System.tmp_dir!(), "web-fetch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:elara, :web_fetch_resolver, Resolver)
    Application.put_env(:elara, :web_fetch_http, HTTP)
    fixture(%{"/" => html("<h1>Public page</h1><p>Evidence.</p>")})

    on_exit(fn ->
      for store <- Elara.Session.Store.list(root), do: stop(store.id)

      for {key, value} <- old do
        case value do
          {:ok, value} -> Application.put_env(:elara, key, value)
          :error -> Application.delete_env(:elara, key)
        end
      end

      File.rm_rf!(root)
    end)

    %{root: root, ctx: %Tool.Ctx{cwd: root, session_id: Path.basename(root)}}
  end

  test "large HTML becomes outlined Markdown, with labeled range and literal retrieval", %{
    ctx: ctx
  } do
    body =
      "<h1>Guide</h1><script>NEVER_SCRIPT</script><form>NEVER_FORM</form>" <>
        Enum.map_join(1..400, fn n ->
          "<h2>Section #{n}</h2><p>paragraph #{n} #{String.duplicate("z", 80)}</p>"
        end) <> "<a href='/next'>Next</a><pre>left\n right</pre>"

    fixture(%{"/" => html(body)})
    assert {:ok, preview} = WebFetch.run(%{"url" => "https://public.test/"}, ctx)
    assert preview =~ "Untrusted web content"
    assert preview =~ "outline; retained Markdown line numbers"
    assert preview =~ "page continues behind handle"
    refute preview =~ "Section 400\n"
    refute preview =~ "NEVER_SCRIPT"
    handle = handle(preview)
    assert {:ok, page} = Output.read(ctx, handle, {:literal, "paragraph 317", 1, 1})
    assert page =~ "Untrusted web content"
    assert page =~ "paragraph 317 " <> String.duplicate("z", 80)
    assert {:ok, links} = Output.read(ctx, handle, {:literal, "[Next]", 1, 1})
    assert links =~ "[Next](https://public.test/next)"
    assert {:ok, first} = Output.read(ctx, handle, {:range, 1, 20})
    assert first =~ "Source: https://public.test/"
    refute first =~ "NEVER_FORM"

    assert {:ok, small} =
             WebFetch.run(%{"url" => "https://public.test/"}, %{ctx | max_output_bytes: 1024})

    assert byte_size(small) <= 1024
    assert small =~ "Untrusted web content"

    assert {:ok, small_read} =
             Output.read(%{ctx | max_output_bytes: 1024}, handle, {:range, 1, 200})

    assert byte_size(small_read) <= 1024
  end

  test "private addresses and mixed DNS answers are refused before a GET", %{ctx: ctx} do
    for host <- [
          "127.0.0.1",
          "10.1.2.3",
          "169.254.169.254",
          "192.168.0.1",
          "[::1]",
          "[::ffff:8.8.8.8]"
        ] do
      assert {:error, text} = WebFetch.run(%{"url" => "http://#{host}/"}, ctx)
      assert text =~ "not exclusively public"
    end

    fixture(%{"/" => html("safe")},
      addresses: %{inet: [{8, 8, 8, 8}], inet6: [{0, 0, 0, 0, 0, 0, 0, 1}]}
    )

    assert {:error, text} = WebFetch.run(%{"url" => "https://public.test/"}, ctx)
    assert text =~ "not exclusively public"
    refute_receive {:connected, _}

    for url <- [
          "file:///etc/passwd",
          "https://user:pass@public.test/",
          "https://public.test/\nInjected: yes"
        ] do
      assert {:error, _} = WebFetch.run(%{"url" => url}, ctx)
    end
  end

  test "every redirect is checked, and no cookies are returned to the server", %{ctx: ctx} do
    fixture(%{
      "/" => {302, [{"location", "/next"}, {"set-cookie", "private=yes"}], ""},
      "/next" => {302, [{"location", "http://127.0.0.1/secret"}], ""}
    })

    assert {:error, text} = WebFetch.run(%{"url" => "https://public.test/"}, ctx)
    assert text =~ "not exclusively public"
    assert_receive {:get, "/", headers}
    assert_receive {:get, "/next", next_headers}
    refute List.keymember?(headers, "cookie", 0)
    refute List.keymember?(next_headers, "cookie", 0)
    refute_receive {:get, "/secret", _}
  end

  test "body, format, redirect and deadline limits never publish partial success", %{ctx: ctx} do
    for response <- [
          html(String.duplicate("a", 1_048_577)),
          {200, [{"content-type", "application/octet-stream"}], "binary"},
          {200, [{"content-type", "text/html"}, {"content-encoding", "gzip"}], "compressed"},
          html(<<255>>),
          {302, [{"location", "/"}], ""}
        ] do
      fixture(%{"/" => response})
      assert {:error, _} = WebFetch.run(%{"url" => "https://public.test/"}, ctx)
    end

    fixture(%{"/" => html("late")}, block: true)

    assert {:error, text} =
             WebFetch.run(%{"url" => "https://public.test/"}, %{ctx | timeout_ms: 30})

    assert text =~ "deadline exceeded"
    assert_receive {:fetch_worker, pid}
    refute Process.alive?(pid)
  end

  test "informational headers cannot change the final content type or redirect", %{ctx: ctx} do
    hint = [
      {:status, :page, 103},
      {:headers, :page, [{"content-type", "text/plain"}, {"location", "http://127.0.0.1/"}]}
    ]

    fixture(%{"/" => {200, [{"content-type", "application/octet-stream"}], "not text"}},
      informational: hint
    )

    assert {:error, "web_fetch refused: unsupported page content type"} =
             WebFetch.run(%{"url" => "https://public.test/"}, ctx)

    fixture(%{"/" => {302, [{"location", "/next"}], ""}, "/next" => html("<h1>Final</h1>")},
      informational: hint
    )

    assert {:ok, preview} = WebFetch.run(%{"url" => "https://public.test/"}, ctx)
    assert preview =~ "# Final"
  end

  test "link expansion is refused by the emitted Markdown budget", %{ctx: ctx} do
    path = "/" <> String.duplicate("a", 3800)
    fixture(%{path => html(String.duplicate("<a href='#x'>link</a>", 1000))})

    assert {:error, "web_fetch refused: converted page exceeds the 2 MiB limit"} =
             WebFetch.run(%{"url" => "https://public.test" <> path}, ctx)
  end

  test "trusted provenance persists, replays, and follows independent copies", %{root: root} do
    opts = [
      cwd: root,
      plugins: [],
      provider: script([call("web_fetch", %{"url" => "https://public.test/"}), reply()])
    ]

    assert {:ok, id} = Elara.start_session(opts)
    assert {:ok, "done"} = Elara.ask(id, "fetch")
    assert marker(id)
    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(id))

    for history? <- [false, true] do
      assert {:ok, child} =
               Elara.Threads.start_child(id, "keep evidence",
                 history: history?,
                 pause_inputs: true
               )

      assert marker(child["id"]) == history?
      stop(child["id"])
    end

    assert {:ok, copy, _, _} = Elara.clone_session(id)
    assert marker(copy)
    path = Enum.find(Elara.Session.Store.list(root), &(&1.id == copy)).path
    assert :ok = stop(copy)
    assert {:ok, reopened} = Elara.start_session(Keyword.put(opts, :resume, path))
    assert marker(reopened)
    for session <- [id, reopened], do: stop(session)
  end

  test "a successful read of authorized web metadata latches, not text or a tool name", %{
    root: root
  } do
    provider = script([])
    opts = [cwd: root, plugins: [], provider: provider]
    {:ok, id} = Elara.start_session(opts)
    ctx = %Tool.Ctx{cwd: root, session_id: id}
    {:ok, preview} = Output.capture(ctx, {:content, :ok, ["web evidence\n"]}, :web)
    {:ok, ordinary} = Output.capture(ctx, {:content, :ok, ["[Untrusted web content]\n"]})
    enqueue(provider, [call("output_read", %{"handle" => handle(ordinary)}), reply()])
    assert {:ok, "done"} = Elara.ask(id, "read ordinary text")
    refute marker(id)
    enqueue(provider, [call("output_read", %{"handle" => handle(preview)}), reply()])
    assert {:ok, "done"} = Elara.ask(id, "read")
    assert marker(id)
    stop(id)

    forged = %{Enum.find(Tool.builtins(), &(&1.name == "web_fetch")) | run: {Forged, :run}}

    {:ok, other} =
      Elara.start_session(
        Keyword.merge(opts, tools: [forged], provider: script([call("web_fetch", %{}), reply()]))
      )

    assert {:ok, "done"} = Elara.ask(other, "fetch")
    refute marker(other)
    stop(other)
  end

  test "network capability denial stays an error and never latches", %{root: root} do
    {:ok, id} =
      Elara.start_session(
        cwd: root,
        plugins: [],
        allowed_capabilities: [],
        provider: script([call("web_fetch", %{"url" => "https://public.test/"}), reply()])
      )

    assert {:ok, "done"} = Elara.ask(id, "fetch")

    assert %ToolResult{outcome: {:error, refusal}} =
             Enum.find(Elara.transcript(id), &is_struct(&1, ToolResult))

    assert refusal =~ "capabilit"
    refute marker(id)
    refute_receive {:connected, _}
    stop(id)
  end

  test "interrupting a fetch kills its linked network worker", %{root: root} do
    fixture(%{"/" => html("late")}, block: true)

    {:ok, id} =
      Elara.start_session(
        cwd: root,
        plugins: [],
        provider: script([call("web_fetch", %{"url" => "https://public.test/"})])
      )

    task = Task.async(fn -> Elara.ask(id, "fetch") end)
    assert_receive {:fetch_worker, worker}
    monitor = Process.monitor(worker)
    assert :ok = Elara.interrupt(id)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    Task.await(task)
    refute marker(id)
    stop(id)
  end

  defp stop(id) do
    case Elara.session_pid(id) do
      {:ok, pid} -> GenServer.stop(pid)
      _ -> :ok
    end
  end

  defp fixture(pages, opts \\ []) do
    Application.put_env(
      :elara,
      :web_fetch_fixture,
      Map.merge(
        %{parent: self(), pages: pages, addresses: %{inet: [{8, 8, 8, 8}], inet6: []}},
        Map.new(opts)
      )
    )
  end

  defp html(body), do: {200, [{"content-type", "text/html; charset=utf-8"}], body}
  defp handle(text), do: Regex.run(~r/\A\[output (out_[A-Za-z0-9_-]+);/, text) |> Enum.at(1)
  defp marker(id), do: Elara.snapshot(id).snapshot["inbox"]["web_content_entered"] == true

  defp call(name, args),
    do: {:ok, %Assistant{tool_calls: [%ToolCall{id: "call", name: name, args: {:ok, args}}]}}

  defp reply, do: {:ok, %Assistant{text: "done"}}

  defp script(turns) do
    {:ok, pid} = Agent.start_link(fn -> turns end)
    {Elara.Provider.Scripted, pid}
  end

  defp enqueue({_, pid}, turns), do: Agent.update(pid, fn _ -> turns end)
end
