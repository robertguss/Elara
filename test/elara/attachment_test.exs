defmodule Elara.AttachmentTest do
  use ExUnit.Case, async: true
  alias Elara.Attachment

  setup do
    cwd = Path.join(System.tmp_dir!(), "elara-input-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    %{cwd: cwd}
  end

  test "explicit text is immutable and ordinary @prose is inert", %{cwd: cwd} do
    File.write!(Path.join(cwd, "日本 file.txt"), "original")
    assert {:ok, user} = Attachment.prepare(cwd, "@unknown", ["日本 file.txt"], [])
    File.rm!(Path.join(cwd, "日本 file.txt"))
    assert user.text == "@unknown"
    assert hd(user.attachments)["content"] == "original"

    assert {:ok, ^user} =
             user |> Elara.Session.Store.encode_message() |> Elara.Session.Store.decode_message()

    assert {:ok, %{attachments: []}} = Attachment.prepare(cwd, "@missing", [], [])
  end

  test "missing, escape, binary text and selection limits fail", %{cwd: cwd} do
    assert {:error, _} = Attachment.prepare(cwd, "", ["missing"], [])
    assert {:error, _} = Attachment.prepare(cwd, "", ["../outside"], [])
    File.write!(Path.join(cwd, "binary"), <<255>>)
    assert {:error, _} = Attachment.prepare(cwd, "", ["binary"], [])
    assert {:error, _} = Attachment.prepare(cwd, "", List.duplicate("x", 5), [])
  end

  test "PNG bytes validate and survive persistence", %{cwd: cwd} do
    png = png()
    assert {:ok, image} = Attachment.ingest_image("outside.png", Base.encode64(png))
    assert image["mime_type"] == "image/png"
    {:ok, renamed} = Attachment.ingest_image("other.png", Base.encode64(png))
    refute renamed["id"] == image["id"]
    assert {:ok, user} = Attachment.prepare(cwd, "look", [], [image])

    assert {:ok, ^user} =
             user |> Elara.Session.Store.encode_message() |> Elara.Session.Store.decode_message()

    assert {:error, _} = Attachment.ingest_image("fake.png", Base.encode64("garbage"))

    assert {:error, _} =
             Attachment.ingest_image("big.png", Base.encode64(:binary.copy(<<0>>, 2_097_153)))
  end

  test "clipped text reports included bytes and empty files remain explicit", %{cwd: cwd} do
    File.write!(Path.join(cwd, "long"), String.duplicate("é", 40_000))
    File.write!(Path.join(cwd, "empty"), "")
    assert {:ok, user} = Attachment.prepare(cwd, "review", ["long", "empty"], [])
    [long, empty] = user.attachments
    assert long["clipped"] and long["included_bytes"] == 65_536
    assert String.valid?(long["content"])
    assert empty["content"] == ""
    assert Attachment.provider_text(user) =~ "clipped to 65536 bytes"
  end

  test "discovery is fuzzy, Unicode-safe, bounded, and skips symlinks", %{cwd: cwd} do
    File.write!(Path.join(cwd, "日本 file.txt"), "hello")
    File.ln_s!("/etc/passwd", Path.join(cwd, "escape"))

    assert {:ok, %{files: [%{path: "日本 file.txt", bytes: 5}], truncated: false}} =
             Attachment.discover(cwd, "日ft")

    assert {:ok, %{files: []}} = Attachment.discover(cwd, "nomatch")
    assert {:error, _} = Attachment.prepare(cwd, "", ["escape"], [])
    assert {:error, _} = Attachment.discover(Path.join(cwd, "missing"), "")
    for n <- 1..60, do: File.write!(Path.join(cwd, "file#{n}"), "")
    assert {:ok, %{files: files, truncated: true}} = Attachment.discover(cwd, "file")
    assert length(files) == 50
  end

  test "corrupt CRC, truncated data, invalid scanline and decoded size bombs fail" do
    data = png()
    <<first, rest::binary>> = data
    assert {:error, _} = Attachment.ingest_image("x", Base.encode64(<<first + 1, rest::binary>>))

    assert {:error, _} =
             Attachment.ingest_image(
               "x",
               Base.encode64(binary_part(data, 0, byte_size(data) - 1))
             )

    for raw <- [<<5, 1, 2, 3>>, :binary.copy(<<0>>, 100_000)] do
      bomb = png(raw)
      assert {:error, _} = Attachment.ingest_image("x", Base.encode64(bomb))
    end
  end

  test "provider receives image content and metadata-only snapshots remain small", %{cwd: cwd} do
    {:ok, image} = Attachment.ingest_image("image.png", Base.encode64(png()))
    {:ok, user} = Attachment.prepare(cwd, "look", [], [image])
    config = %Elara.Provider.OpenAICodex{model: "test", effort: "low"}

    body =
      Elara.Provider.OpenAICodex.build_body(config, %Elara.Provider.Request{
        system: "test",
        messages: [user],
        tools: []
      })

    assert [
             %{
               "content" => [
                 %{"type" => "input_text", "text" => "look"},
                 %{"type" => "input_image", "image_url" => url}
               ]
             }
           ] = body["input"]

    assert url == "data:image/png;base64," <> image["base64"]
    core = Elara.Session.Core.new(%Elara.Session.Core.Config{system: "test", tools: %{}}, [user])
    snapshot = Elara.Protocol.snapshot("test", "incarnation", core)
    refute JSON.encode!(snapshot) =~ image["base64"]
    assert hd(snapshot["messages"])["attachments"] == [Attachment.metadata(image)]

    corrupt =
      put_in(
        Elara.Session.Store.encode_message(user),
        ["user", "attachments", Access.at(0), "id"],
        "wrong"
      )

    assert {:error, _} = Elara.Session.Store.decode_message(corrupt)
  end

  test "session API, persisted restart and seeded handoff preserve owned inputs", %{cwd: cwd} do
    File.write!(Path.join(cwd, "source"), "submission content")
    {:ok, image} = Attachment.ingest_image("image.png", Base.encode64(png()))
    {:ok, assistant} = Elara.Message.assistant("done", [])
    {:ok, agent} = Agent.start_link(fn -> [{:ok, assistant}, {:ok, assistant}] end)

    {:ok, session} =
      Elara.start_session(provider: {Elara.Provider.Scripted, agent}, cwd: cwd, persist: false)

    {:ok, pid} = Elara.session_pid(session)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert {:ok, "done"} = Elara.ask_input(session, "look", ["source"], [image])
    [user, _] = Elara.transcript(session)
    File.rm!(Path.join(cwd, "source"))
    store = %{Elara.Session.Store.new(cwd) | path: Path.join(cwd, "session.jsonl")}
    {:ok, store} = Elara.Session.Store.append(store, user)
    assert {:ok, reopened} = Elara.Session.Store.open(store.path, cwd)
    assert [^user] = Elara.Session.Store.history(reopened)

    {:ok, child} =
      Elara.start_session(
        provider: {Elara.Provider.Scripted, agent},
        cwd: cwd,
        persist: false,
        seed_history: Elara.Session.Store.history(reopened)
      )

    {:ok, child_pid} = Elara.session_pid(child)
    on_exit(fn -> if Process.alive?(child_pid), do: GenServer.stop(child_pid) end)
    assert {:ok, "done"} = Elara.ask(child, "follow up")
    assert hd(Elara.transcript(child)) == user
    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(session))
  end

  test "unsupported providers reject images before accepting the user turn", %{cwd: cwd} do
    {:ok, image} = Attachment.ingest_image("image.png", Base.encode64(png()))

    provider =
      {Elara.Provider.OpenAI,
       %Elara.Provider.OpenAI{model: "test", base_url: "http://127.0.0.1:1", api_key: "test"}}

    {:ok, session} = Elara.start_session(provider: provider, cwd: cwd, persist: false)
    {:ok, pid} = Elara.session_pid(session)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:error, :images_unsupported_by_provider} =
             Elara.ask_input(session, "look", [], [image])

    assert [] = Elara.transcript(session)
  end

  test "negotiated RPCs handle pipelined writes, fragmented JSON and discard", %{
    cwd: cwd
  } do
    File.write!(Path.join(cwd, "file name"), "hello")
    {:ok, agent} = Agent.start_link(fn -> [] end)

    {:ok, session} =
      Elara.start_session(provider: {Elara.Provider.Scripted, agent}, cwd: cwd, persist: false)

    {:ok, pid} = Elara.session_pid(session)
    {:ok, server} = Elara.Server.start_link(port: 0)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Elara.Server.port(server), [
        :binary,
        packet: :line,
        active: false
      ])

    on_exit(fn -> :gen_tcp.close(socket) end)

    send_rpc(socket, %{
      version: 2,
      command: "attach",
      session_id: session,
      extensions: ["input_attachments_v1"]
    })

    assert "input_attachments_v1" in receive_rpc(socket)["extensions"]

    query = %{
      version: 2,
      command: "discover_files",
      extension: "input_attachments_v1",
      query: "fn",
      request_id: "1"
    }

    :ok =
      :gen_tcp.send(socket, [
        Elara.Protocol.encode(query),
        Elara.Protocol.encode(%{query | request_id: "2"})
      ])

    assert %{"request_id" => "1", "files" => [%{"path" => "file name"}]} = receive_rpc(socket)
    assert %{"request_id" => "2", "type" => "ok"} = receive_rpc(socket)
    encoded = IO.iodata_to_binary(Elara.Protocol.encode(%{query | request_id: "3"}))
    <<prefix::binary-size(10), rest::binary>> = encoded
    :ok = :gen_tcp.send(socket, prefix)
    :ok = :gen_tcp.send(socket, rest)
    assert %{"request_id" => "3", "type" => "ok"} = receive_rpc(socket)

    upload = %{
      version: 2,
      command: "ingest_image",
      extension: "input_attachments_v1",
      request_id: "4",
      name: "img.png",
      base64: Base.encode64(png())
    }

    for _ <- 1..20 do
      send_rpc(socket, upload)
      assert %{"type" => "ok", "attachment" => %{"id" => id}} = receive_rpc(socket)

      send_rpc(socket, %{
        version: 2,
        command: "discard_attachment",
        extension: "input_attachments_v1",
        request_id: "5",
        attachment_id: id
      })

      assert %{"type" => "ok"} = receive_rpc(socket)
    end

    send_rpc(socket, %{
      version: 2,
      command: "ask",
      extension: "input_attachments_v1",
      prompt: "look",
      attachment_ids: ["missing"],
      references: []
    })

    assert %{"type" => "error", "error" => "unknown_attachment_reselect_image"} =
             receive_rpc(socket)

    assert [] = Elara.transcript(session)
    send_rpc(socket, %{version: 2, command: "ask", prompt: "literal", references: ["file name"]})
    assert %{"type" => "error", "error" => "unsupported_extension"} = receive_rpc(socket)
  end

  test "interrupt preserves accepted attachment history", %{cwd: cwd} do
    {:ok, image} = Attachment.ingest_image("image.png", Base.encode64(png()))
    {:ok, assistant} = Elara.Message.assistant("done", [])

    {:ok, agent} =
      Agent.start_link(fn -> [{:stream, ["started", {:sleep, 5_000}], {:ok, assistant}}] end)

    {:ok, session} =
      Elara.start_session(provider: {Elara.Provider.Scripted, agent}, cwd: cwd, persist: false)

    {:ok, pid} = Elara.session_pid(session)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok = Elara.subscribe(session)
    task = Task.async(fn -> Elara.ask_input(session, "look", [], [image]) end)
    assert_receive {:elara, ^session, {:content_delta, _id, "started"}}
    Elara.interrupt(session)
    assert {:error, :interrupted} = Task.await(task)
    assert hd(Elara.transcript(session)).attachments == [image]
  end

  test "explicit prompt cap rejects oversized input without reading references", %{cwd: cwd} do
    assert {:error, :input_too_large} =
             Attachment.prepare(cwd, String.duplicate("x", 1_048_577), ["missing"], [])
  end

  test "image history reports unknown context cost without serializing image blobs" do
    image = %{"kind" => "image", "base64" => String.duplicate("a", 2_796_204)}
    user = %Elara.Message.User{text: "look", attachments: [image]}
    config = %Elara.Session.Core.Config{system: "test", tools: %{}}
    core = Elara.Session.Core.new(config, [user])

    for _ <- 1..20 do
      context = Elara.Provider.Visibility.view(core)["context"]
      assert context["estimate_tokens"] == nil
      assert context["occupancy"] == nil
      assert context["estimate_basis"] =~ "images"
      assert byte_size(JSON.encode!(Elara.Provider.Visibility.view(core))) < 1024
    end

    text_core = Elara.Session.Core.new(config, [%{user | attachments: []}])
    assert Elara.Provider.Visibility.view(text_core)["context"]["estimate_tokens"] > 4096
  end

  test "replaced FIFO input fails promptly and session accepts a corrected draft", %{cwd: cwd} do
    path = Path.join(cwd, "selected 日本 file")
    File.write!(path, "selected")
    assert {:ok, %{files: [_]}} = Attachment.discover(cwd, "selected")
    File.rm!(path)
    assert {_, 0} = System.cmd("mkfifo", [path])
    {:ok, assistant} = Elara.Message.assistant("done", [])
    {:ok, agent} = Agent.start_link(fn -> [{:ok, assistant}] end)

    {:ok, session} =
      Elara.start_session(provider: {Elara.Provider.Scripted, agent}, cwd: cwd, persist: false)

    {:ok, pid} = Elara.session_pid(session)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:error, :invalid_file} =
             Elara.ask_input(session, "draft", [Path.basename(path)], [], 2_000)

    assert [] = Elara.transcript(session)

    # Directly exercise the opened-descriptor guard too: this is what receives
    # a path replaced after the Elixir lstat, and must not await a FIFO writer.
    helper = Application.app_dir(:elara, "priv/native/exec-stub")

    assert {:ok, %{termination: :exited, code: 1}} =
             Elara.Exec.run([helper, "--read-attachment", path], cwd: cwd, timeout_ms: 250)

    File.rm!(path)
    File.write!(path, "corrected")
    assert {:ok, "done"} = Elara.ask_input(session, "draft", [Path.basename(path)], [], 2_000)
    assert hd(Elara.transcript(session)).text == "draft"
    assert hd(hd(Elara.transcript(session)).attachments)["content"] == "corrected"
  end

  defp send_rpc(socket, request), do: :gen_tcp.send(socket, Elara.Protocol.encode(request))

  defp receive_rpc(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    JSON.decode!(line)
  end

  defp png(raw \\ <<0, 255, 0, 0>>) do
    chunk = fn type, data ->
      <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
    end

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk.("IHDR", <<1::32, 1::32, 8, 2, 0, 0, 0>>) <>
      chunk.("IDAT", :zlib.compress(raw)) <> chunk.("IEND", "")
  end
end

defmodule Elara.AttachmentTimeoutTest do
  # Suspending the shared execution boundary must not overlap other test jobs.
  use ExUnit.Case, async: false

  test "a stalled input job times out, releases its worker and leaves the draft retryable" do
    cwd =
      Path.join(System.tmp_dir!(), "elara-input-timeout-#{System.unique_integer([:positive])}")

    File.mkdir_p!(cwd)
    File.write!(Path.join(cwd, "input"), "contents")
    {:ok, assistant} = Elara.Message.assistant("done", [])
    {:ok, agent} = Agent.start_link(fn -> [{:ok, assistant}] end)

    {:ok, session} =
      Elara.start_session(provider: {Elara.Provider.Scripted, agent}, cwd: cwd, persist: false)

    {:ok, pid} = Elara.session_pid(session)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(cwd)
    end)

    before_tasks = Task.Supervisor.children(Elara.TaskSup)
    :ok = :sys.suspend(Elara.Exec)

    try do
      assert {:error, :file_read_timeout_retry} =
               Elara.ask_input(session, "retained draft", ["input"], [], 2_000)

      assert [] = Elara.transcript(session)
      assert Task.Supervisor.children(Elara.TaskSup) == before_tasks
    after
      :sys.resume(Elara.Exec)
    end

    # The execution owner observes the dead caller and cancels/reaps its job.
    Enum.reduce_while(1..100, nil, fn _, _ ->
      if Elara.Exec.status().jobs == 0 do
        {:halt, nil}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end)

    assert Elara.Exec.status().jobs == 0
    assert {:ok, "done"} = Elara.ask_input(session, "retained draft", ["input"], [], 2_000)
    assert hd(Elara.transcript(session)).text == "retained draft"
  end
end
