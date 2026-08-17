defmodule Harness.Session.StoreTest do
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]

  alias Harness.Message
  alias Harness.Message.{ToolCall, ToolResult}
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

  test "append atomically writes a private linked spine", %{root: root, cwd: cwd} do
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
             "leaf" => store.leaf
           }

    assert first["parentId"] == nil
    assert second["parentId"] == first["id"]
    assert third["parentId"] == second["id"]
    assert third["id"] == store.leaf
    assert is_integer(first["timestamp"])
    assert Map.keys(first) |> Enum.sort() == ["id", "parentId", "timestamp", "user"]

    assert {:ok, reopened} = Store.open(store.path, cwd)
    assert Store.history(reopened) == [user, assistant, result]
  end

  test "history walks only the selected leaf spine in model order", %{cwd: cwd} do
    store = Store.new(cwd)
    user = Message.user("root")
    {:ok, branch_a} = Message.assistant("branch a", [])

    call = %ToolCall{id: "branch-call", name: "read", args: {:ok, %{"path" => "b.txt"}}}
    {:ok, branch_b} = Message.assistant(nil, [call])
    branch_b_result = Message.tool_result(call, {:ok, "branch b"})

    header = header(store, "branch-b-result")

    entries = [
      entry("root", nil, 1, user),
      entry("branch-a", "root", 2, branch_a),
      entry("branch-b", "root", 3, branch_b),
      entry("branch-b-result", "branch-b", 4, branch_b_result)
    ]

    write_lines(store.path, header, entries)

    assert {:ok, reopened} = Store.open(store.path, cwd)
    assert Store.history(reopened) == [user, branch_b, branch_b_result]
  end

  test "history derives interrupted results without rewriting the file", %{cwd: cwd} do
    first = %ToolCall{id: "call-1", name: "read", args: {:ok, %{"path" => "a"}}}
    second = %ToolCall{id: "call-2", name: "read", args: {:ok, %{"path" => "b"}}}
    {:ok, assistant} = Message.assistant(nil, [first, second])
    completed = Message.tool_result(first, {:ok, "a"})

    store = Store.new(cwd)
    assert {:ok, store} = Store.append(store, Message.user("read both"))
    assert {:ok, store} = Store.append(store, assistant)
    assert {:ok, store} = Store.append(store, completed)
    before = File.read!(store.path)

    assert [
             %Message.User{},
             ^assistant,
             ^completed,
             %ToolResult{call_id: "call-2", name: "read", outcome: {:error, "interrupted"}}
           ] = Store.history(store)

    assert File.read!(store.path) == before
  end

  test "open rejects unsupported versions and bad headers", %{cwd: cwd} do
    store = Store.new(cwd)

    write_lines(store.path, %{header(store, nil) | "version" => 2}, [])
    assert {:error, {:unsupported_version, 2}} = Store.open(store.path, cwd)

    write_lines(store.path, %{"version" => 1, "id" => store.id, "leaf" => nil}, [])
    assert {:error, :bad_header} = Store.open(store.path, cwd)
  end

  test "open rejects duplicate IDs, missing parents, and cycles", %{cwd: cwd} do
    store = Store.new(cwd)
    message = Message.user("x")

    write_lines(
      store.path,
      header(store, "same"),
      [entry("same", nil, 1, message), entry("same", nil, 2, message)]
    )

    assert {:error, {:duplicate_id, "same"}} = Store.open(store.path, cwd)

    write_lines(
      store.path,
      header(store, "orphan"),
      [entry("orphan", "absent", 1, message)]
    )

    assert {:error, {:missing_parent, "absent"}} = Store.open(store.path, cwd)

    write_lines(
      store.path,
      header(store, "a"),
      [entry("a", "b", 1, message), entry("b", "a", 2, message)]
    )

    assert {:error, {:cycle, _id}} = Store.open(store.path, cwd)
  end

  test "open rejects disconnected roots", %{cwd: cwd} do
    store = Store.new(cwd)
    message = Message.user("x")

    write_lines(
      store.path,
      header(store, "selected-root"),
      [
        entry("selected-root", nil, 1, message),
        entry("disconnected-root", nil, 2, message)
      ]
    )

    assert {:error, {:disconnected_tree, "disconnected-root"}} = Store.open(store.path, cwd)
  end

  test "open rejects an interior malformed line", %{cwd: cwd} do
    store = Store.new(cwd)

    raw =
      [
        JSON.encode!(header(store, "leaf")),
        JSON.encode!(entry("root", nil, 1, Message.user("root"))),
        "{",
        JSON.encode!(entry("leaf", "root", 2, Message.user("leaf")))
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

    write_lines(store.path, header(store, "root"), [entry("root", nil, 1, user)], "{")

    assert {:ok, reopened} = Store.open(store.path, cwd)
    assert Store.history(reopened) == [user]

    File.write!(store.path, File.read!(store.path) <> "\n{")

    assert {:error, {:malformed_line, 3, :invalid_json}} = Store.open(store.path, cwd)

    invalid_entry =
      user
      |> Store.encode_message()
      |> Map.merge(%{"id" => "schema-error", "timestamp" => 2})
      |> JSON.encode!()

    write_lines(
      store.path,
      header(store, "root"),
      [entry("root", nil, 1, user)],
      invalid_entry
    )

    assert {:error, {:malformed_line, 3, :invalid_entry}} = Store.open(store.path, cwd)
  end

  test "new stores remain unborn until first append", %{root: root, cwd: cwd} do
    store = Store.new(cwd)

    refute File.exists?(store.path)
    refute File.exists?(Path.join(root, Store.cwd_key(cwd)))

    assert {:ok, store} = Store.append(store, Message.user("materialize"))
    assert File.regular?(store.path)
  end

  defp header(store, leaf) do
    %{
      "version" => 1,
      "id" => store.id,
      "cwd" => store.cwd,
      "leaf" => leaf
    }
  end

  defp entry(id, parent_id, timestamp, message) do
    message
    |> Store.encode_message()
    |> Map.merge(%{
      "id" => id,
      "parentId" => parent_id,
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
