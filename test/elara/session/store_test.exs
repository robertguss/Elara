defmodule Elara.Session.StoreTest do
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]

  alias Elara.Message
  alias Elara.Message.ToolCall
  alias Elara.Session.Store

  setup do
    previous_root = Application.get_env(:elara, :sessions_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "elara-session-store-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:elara, :sessions_root, root)

    on_exit(fn ->
      if is_nil(previous_root) do
        Application.delete_env(:elara, :sessions_root)
      else
        Application.put_env(:elara, :sessions_root, previous_root)
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root, cwd: Path.join(root, "project")}
  end

  test "message codecs round-trip domain structs" do
    calls = [
      %ToolCall{id: "call-1", name: "read", args: {:ok, %{"path" => "README.md"}}},
      %ToolCall{id: "call-2", name: "bash", args: {:malformed, "{"}}
    ]

    {:ok, assistant} = Message.assistant("checking", calls)

    messages = [
      Message.user("inspect this"),
      assistant,
      Message.tool_result(hd(calls), {:error, "not found"})
    ]

    for message <- messages do
      assert {:ok, ^message} =
               message
               |> Store.encode_message()
               |> Store.decode_message()
    end
  end

  test "assistant provider state persists across reopen without changing legacy wire shape", %{
    cwd: cwd
  } do
    provider_state = %{
      "openai_codex" => %{
        "output" => [
          %{
            "type" => "reasoning",
            "id" => "rs_1",
            "summary" => [],
            "encrypted_content" => "encrypted"
          }
        ]
      }
    }

    {:ok, with_state} = Message.assistant("answer", [], provider_state)
    encoded = Store.encode_message(with_state)
    assert encoded["assistant"]["providerState"] == provider_state
    assert {:ok, ^with_state} = Store.decode_message(encoded)

    assert {:ok, store} = Store.append(Store.new(cwd), with_state)
    assert {:ok, reopened} = Store.open(store.path, cwd)
    assert Store.history(reopened) == [with_state]

    {:ok, legacy} = Message.assistant("answer", [])
    refute Map.has_key?(Store.encode_message(legacy)["assistant"], "providerState")
  end

  test "append writes a private tree-shaped log", %{root: root, cwd: cwd} do
    store = Store.new(cwd)
    user = Message.user("hello")
    {:ok, assistant} = Message.assistant("hi", [])

    call = %ToolCall{id: "call-1", name: "read", args: {:ok, %{"path" => "a.txt"}}}
    result = Message.tool_result(call, {:ok, "contents"})

    assert {:ok, store} = Store.append(store, user)
    assert {:ok, store} = Store.append(store, assistant)
    assert {:ok, store} = Store.append(store, result)

    assert Path.relative_to(store.path, root) ==
             Path.join(Store.cwd_key(cwd), "#{store.id}.jsonl")

    assert {:ok, stat} = File.stat(store.path)
    assert band(stat.mode, 0o777) == 0o600

    [header, first, second, third] = decode_lines(store.path)

    assert header == %{
             "version" => 1,
             "id" => store.id,
             "cwd" => Path.expand(cwd),
             "leaf" => third["id"]
           }

    assert Map.keys(first) |> Enum.sort() == ["id", "parentId", "timestamp", "user"]
    assert first["parentId"] == nil
    assert second["parentId"] == first["id"]
    assert third["parentId"] == second["id"]
    assert is_integer(first["timestamp"])
    assert second["assistant"]["text"] == "hi"
    assert third["toolResult"]["callId"] == "call-1"

    assert {:ok, reopened} = Store.open(store.path, cwd)
    assert Store.history(reopened) == [user, assistant, result]
  end

  test "history is the file order and does not invent results", %{cwd: cwd} do
    first = %ToolCall{id: "call-1", name: "read", args: {:ok, %{"path" => "a"}}}
    second = %ToolCall{id: "call-2", name: "read", args: {:ok, %{"path" => "b"}}}
    {:ok, assistant} = Message.assistant(nil, [first, second])
    completed = Message.tool_result(first, {:ok, "a"})

    store = Store.new(cwd)
    assert {:ok, store} = Store.append(store, Message.user("read both"))
    assert {:ok, store} = Store.append(store, assistant)
    assert {:ok, store} = Store.append(store, completed)

    assert [
             %Message.User{},
             ^assistant,
             ^completed
           ] = Store.history(store)
  end

  test "moving the leaf creates branches and history walks only the active path", %{cwd: cwd} do
    store = Store.new(cwd)
    assert {:ok, store} = Store.append(store, Message.user("first"))
    first_id = List.last(store.entries).id
    assert {:ok, store} = Store.append(store, elem(Message.assistant("one", []), 1))
    assert {:ok, store} = Store.append(store, Message.user("second"))
    assert {:ok, store} = Store.append(store, elem(Message.assistant("two", []), 1))

    assert {:ok, store, "first"} = Store.move_before_user(store, first_id)
    assert Store.history(store) == []
    assert {:ok, store} = Store.append(store, Message.user("first"))
    assert {:ok, store} = Store.append(store, elem(Message.assistant("alternate", []), 1))

    assert Store.history(store) == [
             Message.user("first"),
             elem(Message.assistant("alternate", []), 1)
           ]

    assert length(store.entries) == 6

    {:ok, reopened} = Store.open(store.path, cwd)
    assert Store.history(reopened) == Store.history(store)
  end

  test "fork copies one path, records its parent, and naming appears in listings", %{cwd: cwd} do
    source = Store.new(cwd)
    assert {:ok, source} = Store.append(source, Message.user("first"))
    assert {:ok, source} = Store.append(source, elem(Message.assistant("one", []), 1))
    assert {:ok, source} = Store.append(source, Message.user("second"))
    second_id = List.last(source.entries).id
    source_history = Store.history(source)

    assert {:ok, clone} = Store.clone(source)
    assert clone.id != source.id
    assert clone.path != source.path
    assert clone.parent_session == source.path
    assert Store.history(clone) == source_history
    assert Store.history(source) == source_history

    assert {:ok, fork, "second"} = Store.fork_before_user(source, second_id)
    assert fork.path != source.path
    assert fork.parent_session == source.path
    assert Store.history(fork) == Enum.take(source_history, 2)
    assert Store.history(source) == source_history

    assert {:ok, fork} = Store.rename(fork, "alternate")
    assert Enum.find(Store.list(cwd), &(&1.path == fork.path)).name == "alternate"

    [header | _] = decode_lines(fork.path)
    assert header["name"] == "alternate"
    assert header["parentSession"] == source.path
  end

  test "open rejects unsupported versions and bad headers", %{cwd: cwd} do
    store = Store.new(cwd)

    write_lines(store.path, %{header(store) | "version" => 2}, [])
    assert {:error, {:unsupported_version, 2}} = Store.open(store.path, cwd)

    write_lines(store.path, %{"version" => 1, "id" => store.id}, [])
    assert {:error, :bad_header} = Store.open(store.path, cwd)
  end

  test "open rejects duplicate IDs", %{cwd: cwd} do
    store = Store.new(cwd)
    message = Message.user("x")

    write_lines(
      store.path,
      header(store),
      [entry("same", 1, message), entry("same", 2, message)]
    )

    assert {:error, {:duplicate_id, "same"}} = Store.open(store.path, cwd)
  end

  test "open rejects an interior malformed line", %{cwd: cwd} do
    store = Store.new(cwd)

    raw =
      [
        JSON.encode!(header(store)),
        JSON.encode!(entry("root", 1, Message.user("root"))),
        "{",
        JSON.encode!(entry("leaf", 2, Message.user("leaf")))
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    File.mkdir_p!(Path.dirname(store.path))
    File.write!(store.path, raw)

    assert {:error, {:malformed_line, 3, :invalid_json}} = Store.open(store.path, cwd)
  end

  test "tree files require parentId on every entry", %{cwd: cwd} do
    store = Store.new(cwd)
    assert {:ok, store} = Store.append(store, Message.user("root"))
    [header, first] = decode_lines(store.path)
    write_lines(store.path, header, [Map.delete(first, "parentId")])

    assert {:error, {:malformed_line, 2, :invalid_entry}} = Store.open(store.path, cwd)
  end

  test "open ignores only one malformed trailing non-empty line", %{cwd: cwd} do
    store = Store.new(cwd)
    user = Message.user("complete")

    write_lines(store.path, header(store), [entry("root", 1, user)], "{")

    assert {:ok, reopened} = Store.open(store.path, cwd)
    assert Store.history(reopened) == [user]

    File.write!(store.path, File.read!(store.path) <> "\n{")

    assert {:error, {:malformed_line, 3, :invalid_json}} = Store.open(store.path, cwd)

    invalid_entry =
      user
      |> Store.encode_message()
      |> Map.merge(%{"id" => "schema-error"})
      |> JSON.encode!()

    write_lines(
      store.path,
      header(store),
      [entry("root", 1, user)],
      invalid_entry
    )

    assert {:error, {:malformed_line, 3, :invalid_entry}} = Store.open(store.path, cwd)
  end

  test "list returns usable sessions by mtime and skips unusable files", %{cwd: cwd} do
    older = Store.new(cwd)
    assert {:ok, older} = Store.append(older, Message.user("older"))

    newer = Store.new(cwd)
    assert {:ok, newer} = Store.append(newer, Message.user("newer"))

    incomplete = Store.new(cwd)
    call = %ToolCall{id: "pending", name: "read", args: {:ok, %{"path" => "x"}}}
    {:ok, pending} = Message.assistant(nil, [call])
    assert {:ok, incomplete} = Store.append(incomplete, Message.user("incomplete"))
    assert {:ok, incomplete} = Store.append(incomplete, pending)

    no_user = Store.new(cwd)
    {:ok, assistant} = Message.assistant("assistant root", [])
    assert {:ok, no_user} = Store.append(no_user, assistant)

    empty = Store.new(cwd)
    write_lines(empty.path, header(empty), [])

    dir = Path.dirname(older.path)
    older_path = Path.join(dir, "zzzz.jsonl")
    newer_path = Path.join(dir, "aaaa.jsonl")
    File.rename!(older.path, older_path)
    File.rename!(newer.path, newer_path)
    File.write!(Path.join(dir, "corrupt.jsonl"), "not json")

    File.touch!(older_path, 1_700_000_100)
    File.touch!(incomplete.path, 1_700_000_200)
    File.touch!(newer_path, 1_700_000_300)
    File.touch!(no_user.path, 1_700_000_400)
    File.touch!(empty.path, 1_700_000_500)

    infos = Store.list(cwd, include_empty: true)

    assert Enum.map(infos, & &1.path) == [
             empty.path,
             no_user.path,
             newer_path,
             incomplete.path,
             older_path
           ]

    assert Enum.map(infos, & &1.timestamp) == [
             1_700_000_500,
             1_700_000_400,
             1_700_000_300,
             1_700_000_200,
             1_700_000_100
           ]

    assert Enum.all?(infos, &(&1.cwd == Path.expand(cwd)))
    assert Enum.map(Store.list(cwd), & &1.path) == [newer_path, incomplete.path, older_path]
    assert {:ok, %{path: ^newer_path}} = Store.newest(cwd)
  end

  test "new stores remain unborn until first save", %{root: root, cwd: cwd} do
    store = Store.new(cwd)

    refute File.exists?(store.path)
    refute File.exists?(Path.join(root, Store.cwd_key(cwd)))
    assert Store.list(cwd) == []
    refute File.exists?(Path.join(root, Store.cwd_key(cwd)))

    assert {:ok, store} = Store.append(store, Message.user("materialize"))
    assert File.regular?(store.path)
  end

  test "named new stores persist a header and appear in list", %{cwd: cwd} do
    store = Store.new(cwd, "manual-startup-name")

    assert File.regular?(store.path)
    [info] = Store.list(cwd)
    assert info.path == store.path
    assert info.name == "manual-startup-name"
    assert info.id == store.id

    [header] = decode_lines(store.path)
    assert header["name"] == "manual-startup-name"
    assert header["id"] == store.id
    assert header["cwd"] == Path.expand(cwd)
    assert header["version"] == 1
    assert Map.has_key?(header, "leaf")

    assert {:ok, renamed} = Store.rename(store, "a different readable name")
    [info] = Store.list(cwd)
    assert info.path == renamed.path
    assert info.name == "a different readable name"
  end

  test "memory stores never touch disk", %{root: root, cwd: cwd} do
    store = Store.memory(cwd)
    assert {:ok, store} = Store.append(store, Message.user("ephemeral"))
    assert Store.history(store) == [Message.user("ephemeral")]
    refute File.exists?(root)
  end

  test "claim is exclusive per path", %{cwd: cwd} do
    store = Store.new(cwd)
    assert {:ok, store} = Store.append(store, Message.user("held"))
    assert {:ok, _} = Store.claim(store)

    task =
      Task.async(fn ->
        {:ok, opened} = Store.open(store.path, cwd)
        Store.claim(opened)
      end)

    assert {:error, :locked} = Task.await(task)
    assert :ok = Store.release(store)

    task =
      Task.async(fn ->
        {:ok, opened} = Store.open(store.path, cwd)
        Store.claim(opened)
      end)

    assert {:ok, _} = Task.await(task)
  end

  test "claim holds an operating-system lock", %{cwd: cwd} do
    store = Store.new(cwd)
    assert {:ok, store} = Store.append(store, Message.user("held"))
    assert {:ok, claimed} = Store.claim(store)
    lock_path = store.path <> ".lock"

    assert File.regular?(lock_path)
    assert {_, 1} = System.cmd("flock", ["-n", lock_path, "true"])

    assert :ok = Store.release(claimed)
    assert {_, 0} = System.cmd("flock", ["-n", lock_path, "true"])
  end

  defp header(store) do
    %{
      "version" => 1,
      "id" => store.id,
      "cwd" => store.cwd
    }
  end

  defp entry(id, timestamp, message) do
    message
    |> Store.encode_message()
    |> Map.merge(%{
      "id" => id,
      "timestamp" => timestamp
    })
  end

  defp write_lines(path, header, entries, trailing_fragment \\ nil) do
    payload =
      [header | entries]
      |> Enum.map(&JSON.encode!/1)
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    payload = if is_nil(trailing_fragment), do: payload, else: payload <> trailing_fragment

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, payload)
  end

  defp decode_lines(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end
end
