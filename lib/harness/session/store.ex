defmodule Harness.Session.Store do
  @moduledoc """
  Private JSONL persistence for a session tree.
  """

  alias Harness.Message
  alias Harness.Message.{Assistant, ToolCall, ToolResult, User}

  @version 1
  @hash_length 12

  defmodule Entry do
    @moduledoc false
    @type t :: %__MODULE__{
            id: String.t(),
            parent_id: String.t() | nil,
            timestamp: integer(),
            message: Message.t()
          }
    defstruct [:id, :parent_id, :timestamp, :message]
  end

  defmodule Info do
    @moduledoc false
    @type t :: %__MODULE__{
            path: String.t(),
            id: String.t(),
            cwd: String.t(),
            timestamp: integer(),
            name: String.t() | nil
          }
    defstruct [:path, :id, :cwd, :timestamp, :name]
  end

  @type t :: %__MODULE__{
          id: String.t(),
          cwd: String.t(),
          path: String.t() | nil,
          entries: [Entry.t()],
          leaf: String.t() | nil,
          name: String.t() | nil,
          parent_session: String.t() | nil,
          lock_path: String.t() | nil,
          lock_handle: port() | nil,
          persist?: boolean()
        }

  defstruct [
    :id,
    :cwd,
    :path,
    :leaf,
    :name,
    :parent_session,
    :lock_path,
    :lock_handle,
    entries: [],
    persist?: true
  ]

  @spec root() :: {:ok, String.t()} | {:error, :no_home}
  def root do
    case Application.get_env(:harness, :sessions_root) do
      root when is_binary(root) and root != "" -> {:ok, Path.expand(root)}
      _ -> user_root(System.user_home())
    end
  end

  defp user_root(home) when is_binary(home) and home != "",
    do: {:ok, Path.join([home, ".harness", "sessions"])}

  defp user_root(_home), do: {:error, :no_home}

  @spec new(String.t(), String.t() | nil) :: t()
  def new(cwd, name \\ nil) when is_binary(cwd) do
    cwd = Path.expand(cwd)
    id = generate_id()
    {:ok, root} = root()

    store = %__MODULE__{
      id: id,
      cwd: cwd,
      path: Path.join([root, cwd_key(cwd), "#{id}.jsonl"]),
      name: name
    }

    case name do
      name when is_binary(name) and name != "" ->
        case save(store) do
          {:ok, store} -> store
          {:error, _reason} -> store
        end

      _ ->
        store
    end
  end

  @spec memory(String.t()) :: t()
  def memory(cwd) when is_binary(cwd) do
    %__MODULE__{id: generate_id(), cwd: Path.expand(cwd), path: nil, persist?: false}
  end

  @spec open(String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def open(path, expected_cwd \\ nil) when is_binary(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, header, entry_lines} <- decode_file_lines(raw),
         :ok <- validate_expected_cwd(header.cwd, expected_cwd),
         {:ok, entries} <- decode_entries(entry_lines, header.legacy?),
         {:ok, leaf} <- resolve_leaf(header.leaf, entries) do
      {:ok,
       %__MODULE__{
         id: header.id,
         cwd: header.cwd,
         path: path,
         entries: entries,
         leaf: leaf,
         name: header.name,
         parent_session: header.parent_session
       }}
    end
  end

  @spec append(t(), Message.t()) :: {:ok, t()} | {:error, term()}
  def append(%__MODULE__{} = store, message)
      when is_struct(message, User) or is_struct(message, Assistant) or
             is_struct(message, ToolResult) do
    entry = %Entry{
      id: generate_id(),
      parent_id: store.leaf,
      timestamp: System.system_time(:millisecond),
      message: message
    }

    save(%{store | entries: store.entries ++ [entry], leaf: entry.id})
  end

  @spec history(t()) :: [Message.t()]
  def history(%__MODULE__{} = store) do
    store
    |> path_entries(store.leaf)
    |> Enum.map(& &1.message)
  end

  @spec user_entries(t()) :: [Entry.t()]
  def user_entries(%__MODULE__{entries: entries}) do
    Enum.filter(entries, &is_struct(&1.message, User))
  end

  @spec history_before_user(t(), String.t()) :: {:ok, [Message.t()]} | {:error, :invalid_entry}
  def history_before_user(%__MODULE__{} = store, id) when is_binary(id) do
    case Enum.find(store.entries, &(&1.id == id and is_struct(&1.message, User))) do
      nil ->
        {:error, :invalid_entry}

      entry ->
        history = store |> path_entries(entry.parent_id) |> Enum.map(& &1.message)
        {:ok, history}
    end
  end

  @spec move_before_user(t(), String.t()) :: {:ok, t(), String.t()} | {:error, term()}
  def move_before_user(%__MODULE__{} = store, id) when is_binary(id) do
    case Enum.find(store.entries, &(&1.id == id and is_struct(&1.message, User))) do
      nil ->
        {:error, :invalid_entry}

      entry ->
        case save(%{store | leaf: entry.parent_id}) do
          {:ok, store} -> {:ok, store, entry.message.text}
          error -> error
        end
    end
  end

  @spec clone(t()) :: {:ok, t()} | {:error, term()}
  def clone(%__MODULE__{} = source), do: clone_to(source, source.leaf)

  defp clone_to(source, leaf) do
    entries = path_entries(source, leaf)

    target = %{
      new(source.cwd, source.name)
      | entries: entries,
        leaf: leaf,
        parent_session: source.path
    }

    save(target)
  end

  @spec fork_before_user(t(), String.t()) :: {:ok, t(), String.t()} | {:error, term()}
  def fork_before_user(%__MODULE__{} = source, id) when is_binary(id) do
    case Enum.find(source.entries, &(&1.id == id and is_struct(&1.message, User))) do
      nil ->
        {:error, :invalid_entry}

      entry ->
        case clone_to(source, entry.parent_id) do
          {:ok, target} -> {:ok, target, entry.message.text}
          error -> error
        end
    end
  end

  @spec rename(t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def rename(%__MODULE__{} = store, name) when is_binary(name) or is_nil(name) do
    save(%{store | name: name})
  end

  @spec list(String.t()) :: [Info.t()]
  def list(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)

    with {:ok, root} <- root(),
         {:ok, names} <- File.ls(Path.join(root, cwd_key(cwd))) do
      dir = Path.join(root, cwd_key(cwd))

      names
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.flat_map(&info_for_path(Path.join(dir, &1), cwd))
      |> Enum.sort_by(fn info -> {-info.timestamp, info.path} end)
    else
      _ -> []
    end
  end

  @spec newest(String.t()) :: {:ok, Info.t()} | {:error, :no_session}
  def newest(cwd) when is_binary(cwd) do
    case list(cwd) do
      [info | _] -> {:ok, info}
      [] -> {:error, :no_session}
    end
  end

  @spec claim(t()) :: {:ok, t()} | {:error, term()}
  def claim(%__MODULE__{persist?: false} = store), do: {:ok, store}
  def claim(%__MODULE__{path: nil} = store), do: {:ok, store}

  def claim(%__MODULE__{path: path} = store) do
    key = Path.expand(path)

    case Registry.lookup(Harness.SessionLocks, key) do
      [{pid, {lock_path, lock_handle}}] when pid == self() ->
        {:ok, %{store | lock_path: lock_path, lock_handle: lock_handle}}

      _ ->
        register_lock(key, store)
    end
  end

  defp register_lock(key, store) do
    lock_path = key <> ".lock"

    with {:ok, lock_handle} <- acquire_file_lock(lock_path) do
      case Registry.register(Harness.SessionLocks, key, {lock_path, lock_handle}) do
        {:ok, _} ->
          {:ok, %{store | lock_path: lock_path, lock_handle: lock_handle}}

        {:error, {:already_registered, _}} ->
          close_lock(lock_handle)
          {:error, :locked}
      end
    end
  end

  @spec release(t()) :: :ok
  def release(%__MODULE__{persist?: false}), do: :ok
  def release(%__MODULE__{path: nil}), do: :ok

  def release(%__MODULE__{path: path, lock_handle: lock_handle}) do
    key = Path.expand(path)

    case Registry.lookup(Harness.SessionLocks, key) do
      [{pid, {_lock_path, registered_lock_handle}}] when pid == self() ->
        Registry.unregister(Harness.SessionLocks, key)
        close_lock(lock_handle || registered_lock_handle)

      _ ->
        :ok
    end

    :ok
  end

  defp acquire_file_lock(lock_path) do
    with :ok <- File.mkdir_p(Path.dirname(lock_path)),
         flock when is_binary(flock) <- System.find_executable("flock") do
      port =
        Port.open(
          {:spawn_executable, flock},
          [
            :binary,
            :exit_status,
            {:args, ["-n", lock_path, "sh", "-c", "printf ready; cat"]}
          ]
        )

      receive do
        {^port, {:data, "ready"}} ->
          :ok = File.chmod(lock_path, 0o600)
          {:ok, port}

        {^port, {:exit_status, _status}} ->
          {:error, :locked}
      after
        5_000 ->
          close_lock(port)
          {:error, :lock_timeout}
      end
    else
      nil -> {:error, :lock_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_lock(port) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp close_lock(nil), do: :ok

  @doc false
  def cwd_key(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)

    slug =
      cwd
      |> Path.basename()
      |> String.replace(~r/[^[:alnum:]_.-]+/u, "-")
      |> String.trim("-")
      |> case do
        "" -> "root"
        value -> value
      end

    hash =
      :sha256
      |> :crypto.hash(cwd)
      |> Base.encode16(case: :lower)
      |> binary_part(0, @hash_length)

    "#{slug}-#{hash}"
  end

  @doc false
  def encode_message(%User{text: text}), do: %{"user" => %{"text" => text}}

  def encode_message(%Assistant{text: text, tool_calls: tool_calls}) do
    %{"assistant" => %{"text" => text, "toolCalls" => Enum.map(tool_calls, &encode_tool_call/1)}}
  end

  def encode_message(%ToolResult{call_id: call_id, name: name, outcome: outcome}) do
    %{
      "toolResult" => %{
        "callId" => call_id,
        "name" => name,
        "outcome" => encode_outcome(outcome)
      }
    }
  end

  @doc false
  def decode_message(%{"user" => %{"text" => text} = user} = encoded)
      when map_size(encoded) == 1 and map_size(user) == 1 and is_binary(text),
      do: {:ok, %User{text: text}}

  def decode_message(%{"assistant" => payload} = encoded) when map_size(encoded) == 1 do
    with %{"text" => text, "toolCalls" => calls} = assistant
         when map_size(assistant) == 2 and (is_binary(text) or is_nil(text)) and is_list(calls) <-
           payload,
         {:ok, tool_calls} <- decode_tool_calls(calls),
         {:ok, message} <- Message.assistant(text, tool_calls) do
      {:ok, message}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def decode_message(%{"toolResult" => payload} = encoded) when map_size(encoded) == 1 do
    with %{"callId" => call_id, "name" => name, "outcome" => encoded_outcome} = result
         when map_size(result) == 3 and is_binary(call_id) and call_id != "" and
                is_binary(name) and name != "" <- payload,
         {:ok, outcome} <- decode_outcome(encoded_outcome) do
      {:ok, %ToolResult{call_id: call_id, name: name, outcome: outcome}}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def decode_message(_encoded), do: {:error, :invalid_message}

  defp save(%__MODULE__{persist?: false} = store), do: {:ok, store}
  defp save(%__MODULE__{path: nil}), do: {:error, :no_path}

  defp save(store) do
    lines = [encode_header(store) | Enum.map(store.entries, &encode_entry/1)]
    payload = Enum.map_join(lines, "\n", &JSON.encode!/1) <> "\n"
    dir = Path.dirname(store.path)
    tmp = store.path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, payload),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, store.path) do
      {:ok, store}
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  defp encode_header(store) do
    %{"version" => @version, "id" => store.id, "cwd" => store.cwd, "leaf" => store.leaf}
    |> put_optional("name", store.name)
    |> put_optional("parentSession", store.parent_session)
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp encode_entry(%Entry{} = entry) do
    entry.message
    |> encode_message()
    |> Map.merge(%{
      "id" => entry.id,
      "parentId" => entry.parent_id,
      "timestamp" => entry.timestamp
    })
  end

  defp path_entries(_store, nil), do: []

  defp path_entries(store, leaf) do
    by_id = Map.new(store.entries, &{&1.id, &1})
    walk_entries(by_id, leaf, [])
  end

  defp walk_entries(by_id, id, acc) do
    entry = Map.fetch!(by_id, id)
    acc = [entry | acc]
    if is_nil(entry.parent_id), do: acc, else: walk_entries(by_id, entry.parent_id, acc)
  end

  defp info_for_path(path, cwd) do
    with {:ok, %{type: :regular, mtime: timestamp}} <- File.stat(path, time: :posix),
         {:ok, store} <- open(path, cwd),
         true <- listable?(store) do
      [%Info{path: path, id: store.id, cwd: store.cwd, timestamp: timestamp, name: store.name}]
    else
      _ -> []
    end
  end

  defp listable?(%__MODULE__{name: name}) when is_binary(name) and name != "", do: true

  defp listable?(%__MODULE__{entries: entries}) do
    Enum.any?(entries, &is_struct(&1.message, User))
  end

  defp decode_file_lines(raw) do
    lines = raw |> String.split("\n", trim: false) |> drop_terminal_empty_line()

    case lines do
      [header_line | entry_lines] ->
        case JSON.decode(header_line) do
          {:ok, encoded} ->
            case decode_header(encoded) do
              {:ok, header} -> {:ok, header, entry_lines}
              {:error, reason} -> {:error, reason}
            end

          {:error, _} ->
            {:error, :bad_header}
        end

      [] ->
        {:error, :bad_header}
    end
  end

  defp drop_terminal_empty_line(lines) do
    if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
  end

  defp decode_header(%{"version" => version, "id" => id, "cwd" => cwd} = header) do
    allowed = MapSet.new(["version", "id", "cwd", "leaf", "name", "parentSession"])

    cond do
      not Enum.all?(Map.keys(header), &MapSet.member?(allowed, &1)) ->
        {:error, :bad_header}

      not is_integer(version) ->
        {:error, :bad_header}

      version != @version ->
        {:error, {:unsupported_version, version}}

      not (is_binary(id) and id != "") ->
        {:error, :bad_header}

      not (is_binary(cwd) and cwd != "" and Path.type(cwd) == :absolute) ->
        {:error, :bad_header}

      not valid_optional_string?(Map.get(header, "leaf")) ->
        {:error, :bad_header}

      not valid_optional_string?(Map.get(header, "name")) ->
        {:error, :bad_header}

      not valid_optional_string?(Map.get(header, "parentSession")) ->
        {:error, :bad_header}

      true ->
        {:ok,
         %{
           id: id,
           cwd: cwd,
           leaf: Map.get(header, "leaf", :legacy),
           legacy?: not Map.has_key?(header, "leaf"),
           name: Map.get(header, "name"),
           parent_session: Map.get(header, "parentSession")
         }}
    end
  end

  defp decode_header(_header), do: {:error, :bad_header}
  defp valid_optional_string?(nil), do: true
  defp valid_optional_string?(value), do: is_binary(value) and value != ""

  defp validate_expected_cwd(_stored_cwd, nil), do: :ok

  defp validate_expected_cwd(stored_cwd, expected_cwd) when is_binary(expected_cwd) do
    if stored_cwd == Path.expand(expected_cwd), do: :ok, else: {:error, :cwd_mismatch}
  end

  defp validate_expected_cwd(_stored_cwd, _expected_cwd), do: {:error, :cwd_mismatch}

  defp decode_entries(lines, legacy?) do
    last_index = length(lines) - 1

    lines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new(), nil}, fn {line, index}, acc ->
      decode_entry_reducer(line, index, last_index, legacy?, acc)
    end)
    |> case do
      {:ok, entries, _ids, _previous} -> validate_tree(Enum.reverse(entries))
      {:ok, entries} -> validate_tree(entries)
      error -> error
    end
  end

  defp decode_entry_reducer(line, index, last_index, legacy?, {:ok, entries, ids, previous}) do
    case decode_entry_line(line, legacy?, previous) do
      {:ok, entry} ->
        cond do
          MapSet.member?(ids, entry.id) ->
            {:halt, {:error, {:duplicate_id, entry.id}}}

          not is_nil(entry.parent_id) and not MapSet.member?(ids, entry.parent_id) ->
            {:halt, {:error, {:malformed_line, index + 2, :invalid_parent}}}

          true ->
            {:cont, {:ok, [entry | entries], MapSet.put(ids, entry.id), entry.id}}
        end

      {:error, :invalid_json} when index == last_index and line != "" ->
        {:halt, {:ok, Enum.reverse(entries)}}

      {:error, reason} ->
        {:halt, {:error, {:malformed_line, index + 2, reason}}}
    end
  end

  defp validate_tree(entries), do: {:ok, entries}

  defp decode_entry_line(line, legacy?, legacy_parent) do
    case JSON.decode(line) do
      {:ok, encoded} -> decode_entry(encoded, legacy?, legacy_parent)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp decode_entry(encoded, legacy?, legacy_parent) when is_map(encoded) do
    payload_keys = Enum.filter(["user", "assistant", "toolResult"], &Map.has_key?(encoded, &1))
    expected_size = if legacy?, do: 3, else: 4
    parent = if legacy?, do: legacy_parent, else: Map.get(encoded, "parentId", :missing)

    with [payload_key] <- payload_keys,
         true <- map_size(encoded) == expected_size,
         id when is_binary(id) and id != "" <- Map.get(encoded, "id"),
         timestamp when is_integer(timestamp) <- Map.get(encoded, "timestamp"),
         parent when is_binary(parent) or is_nil(parent) <- parent,
         {:ok, message} <- decode_message(%{payload_key => Map.fetch!(encoded, payload_key)}) do
      {:ok, %Entry{id: id, parent_id: parent, timestamp: timestamp, message: message}}
    else
      _ -> {:error, :invalid_entry}
    end
  end

  defp decode_entry(_encoded, _legacy?, _legacy_parent), do: {:error, :invalid_entry}

  defp resolve_leaf(:legacy, entries), do: {:ok, entries |> List.last() |> entry_id()}
  defp resolve_leaf(nil, _entries), do: {:ok, nil}

  defp resolve_leaf(leaf, entries) do
    if Enum.any?(entries, &(&1.id == leaf)), do: {:ok, leaf}, else: {:error, :invalid_leaf}
  end

  defp entry_id(nil), do: nil
  defp entry_id(entry), do: entry.id

  defp encode_tool_call(%ToolCall{id: id, name: name, args: args}) do
    %{"id" => id, "name" => name, "args" => encode_args(args)}
  end

  defp encode_args({:ok, args}), do: %{"ok" => args}
  defp encode_args({:malformed, raw}), do: %{"malformed" => raw}

  defp decode_tool_calls(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn encoded, {:ok, decoded} ->
      case decode_tool_call(encoded) do
        {:ok, call} -> {:cont, {:ok, [call | decoded]}}
        {:error, :invalid_message} -> {:halt, {:error, :invalid_message}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_tool_call(%{"id" => id, "name" => name, "args" => encoded_args} = call)
       when map_size(call) == 3 and is_binary(id) and id != "" and is_binary(name) and name != "" do
    case decode_args(encoded_args) do
      {:ok, args} -> {:ok, %ToolCall{id: id, name: name, args: args}}
      :error -> {:error, :invalid_message}
    end
  end

  defp decode_tool_call(_call), do: {:error, :invalid_message}

  defp decode_args(%{"ok" => args} = encoded) when map_size(encoded) == 1 and is_map(args),
    do: {:ok, {:ok, args}}

  defp decode_args(%{"malformed" => raw} = encoded)
       when map_size(encoded) == 1 and is_binary(raw),
       do: {:ok, {:malformed, raw}}

  defp decode_args(_encoded), do: :error

  defp encode_outcome({:ok, text}), do: %{"ok" => text}
  defp encode_outcome({:error, text}), do: %{"error" => text}
  defp encode_outcome({:indeterminate, text}), do: %{"indeterminate" => text}

  defp decode_outcome(%{"ok" => text} = encoded)
       when map_size(encoded) == 1 and is_binary(text),
       do: {:ok, {:ok, text}}

  defp decode_outcome(%{"error" => text} = encoded)
       when map_size(encoded) == 1 and is_binary(text),
       do: {:ok, {:error, text}}

  defp decode_outcome(%{"indeterminate" => text} = encoded)
       when map_size(encoded) == 1 and is_binary(text),
       do: {:ok, {:indeterminate, text}}

  defp decode_outcome(_encoded), do: {:error, :invalid_message}

  defp generate_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
