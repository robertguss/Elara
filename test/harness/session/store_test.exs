defmodule Harness.Session.StoreTest do
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]

  alias Harness.Message
  alias Harness.Message.ToolCall
  alias Harness.Session.Store

  setup do
    previous_root = Application.get_env(:harness, :sessions_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "harness-session-store-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:harness, :sessions_root, root)

    on_exit(fn ->
      if is_nil(previous_root) do
        Application.delete_env(:harness, :sessions_root)
      else
        Application.put_env(:harness, :sessions_root, previous_root)
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

  test "append writes a private linear log", %{root: root, cwd: cwd} do
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
             "cwd" => Path.expand(cwd)
           }

    refute Map.has_key?(header, "leaf")
    assert Map.keys(first) |> Enum.sort() == ["id", "timestamp", "user"]
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

    infos = Store.list(cwd)

    assert Enum.map(infos, & &1.path) == [newer_path, incomplete.path, older_path]
    assert Enum.map(infos, & &1.timestamp) == [1_700_000_300, 1_700_000_200, 1_700_000_100]
    assert Enum.all?(infos, &(&1.cwd == Path.expand(cwd)))
    assert {:ok, %{path: ^newer_path}} = Store.newest(cwd)
  end

  test "new stores remain unborn until first append", %{root: root, cwd: cwd} do
    store = Store.new(cwd)

    refute File.exists?(store.path)
    refute File.exists?(Path.join(root, Store.cwd_key(cwd)))
    assert Store.list(cwd) == []
    refute File.exists?(Path.join(root, Store.cwd_key(cwd)))

    assert {:ok, store} = Store.append(store, Message.user("materialize"))
    assert File.regular?(store.path)
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
