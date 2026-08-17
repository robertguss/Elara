defmodule Harness.Session.Store do
  @moduledoc """
  Private JSONL persistence for session message trees.
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
            timestamp: integer()
          }

    defstruct [:path, :id, :cwd, :timestamp]
  end

  @type t :: %__MODULE__{
          id: String.t(),
          cwd: String.t(),
          path: String.t(),
          leaf: String.t() | nil,
          entries: %{String.t() => Entry.t()},
          order: [String.t()]
        }

  defstruct [:id, :cwd, :path, :leaf, entries: %{}, order: []]

  @spec new(String.t()) :: t()
  def new(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)
    id = generate_id()

    %__MODULE__{
      id: id,
      cwd: cwd,
      path: Path.join([sessions_root(), cwd_key(cwd), "#{id}.jsonl"])
    }
  end

  @spec open(String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def open(path, expected_cwd \\ nil) when is_binary(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, header, entry_lines} <- decode_file_lines(raw),
         :ok <- validate_expected_cwd(header.cwd, expected_cwd),
         {:ok, entries, order, trailing_torn?} <- decode_entries(entry_lines),
         leaf = recover_leaf(header.leaf, entries, order, trailing_torn?),
         :ok <- validate_tree(entries, leaf) do
      {:ok,
       %__MODULE__{
         id: header.id,
         cwd: header.cwd,
         path: path,
         leaf: leaf,
         entries: entries,
         order: order
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

    updated = %{
      store
      | leaf: entry.id,
        entries: Map.put(store.entries, entry.id, entry),
        order: store.order ++ [entry.id]
    }

    case rewrite(updated) do
      :ok -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec history(t()) :: [Message.t()]
  def history(%__MODULE__{} = store) do
    store.leaf
    |> walk_to_root(store.entries, [])
    |> derive_interrupted_results()
  end

  @spec list(String.t()) :: [Info.t()]
  def list(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)
    dir = Path.join(sessions_root(), cwd_key(cwd))

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.flat_map(&info_for_path(Path.join(dir, &1), cwd))
        |> Enum.sort_by(fn info -> {-info.timestamp, info.path} end)

      {:error, _reason} ->
        []
    end
  end

  @spec newest(String.t()) :: {:ok, Info.t()} | {:error, :no_session}
  def newest(cwd) when is_binary(cwd) do
    case list(cwd) do
      [info | _] -> {:ok, info}
      [] -> {:error, :no_session}
    end
  end

  @doc false
  @spec cwd_key(String.t()) :: String.t()
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
  @spec encode_message(Message.t()) :: map()
  def encode_message(%User{text: text}) do
    %{"user" => %{"text" => text}}
  end

  def encode_message(%Assistant{text: text, tool_calls: tool_calls}) do
    %{
      "assistant" => %{
        "text" => text,
        "toolCalls" => Enum.map(tool_calls, &encode_tool_call/1)
      }
    }
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
  @spec decode_message(map()) :: {:ok, Message.t()} | {:error, :invalid_message}
  def decode_message(%{"user" => payload} = encoded) when map_size(encoded) == 1 do
    case payload do
      %{"text" => text} = user when map_size(user) == 1 and is_binary(text) ->
        {:ok, %User{text: text}}

      _ ->
        {:error, :invalid_message}
    end
  end

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

  defp sessions_root do
    case Application.get_env(:harness, :sessions_root) do
      root when is_binary(root) and root != "" ->
        Path.expand(root)

      _ ->
        Path.join([System.user_home!(), ".harness", "sessions"])
    end
  end

  defp info_for_path(path, cwd) do
    with {:ok, %{type: :regular, mtime: timestamp}} <- File.stat(path, time: :posix),
         {:ok, store} <- open(path, cwd),
         true <- Enum.any?(history(store), &is_struct(&1, User)) do
      [%Info{path: path, id: store.id, cwd: store.cwd, timestamp: timestamp}]
    else
      _ -> []
    end
  end

  defp rewrite(store) do
    dir = Path.dirname(store.path)
    tmp = store.path <> ".tmp.#{:erlang.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, encode_store(store)),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, store.path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp encode_store(store) do
    header = %{
      "version" => @version,
      "id" => store.id,
      "cwd" => store.cwd,
      "leaf" => store.leaf
    }

    lines = [
      JSON.encode!(header)
      | Enum.map(store.order, fn id ->
          store.entries
          |> Map.fetch!(id)
          |> encode_entry()
          |> JSON.encode!()
        end)
    ]

    Enum.join(lines, "\n") <> "\n"
  end

  defp encode_entry(%Entry{} = entry) do
    entry.message
    |> encode_message()
    |> Map.merge(%{
      "id" => entry.id,
      "parentId" => entry.parent_id,
      "timestamp" => entry.timestamp
    })
  end

  defp decode_file_lines(raw) when is_binary(raw) do
    lines =
      raw
      |> String.split("\n", trim: false)
      |> drop_terminal_empty_line()

    case lines do
      [header_line | entry_lines] ->
        case JSON.decode(header_line) do
          {:ok, encoded_header} ->
            case decode_header(encoded_header) do
              {:ok, header} -> {:ok, header, entry_lines}
              {:error, reason} -> {:error, reason}
            end

          {:error, _reason} ->
            {:error, :bad_header}
        end

      [] ->
        {:error, :bad_header}
    end
  end

  defp drop_terminal_empty_line(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  defp decode_header(
         %{
           "version" => version,
           "id" => id,
           "cwd" => cwd,
           "leaf" => leaf
         } = header
       )
       when map_size(header) == 4 do
    cond do
      not is_integer(version) ->
        {:error, :bad_header}

      version != @version ->
        {:error, {:unsupported_version, version}}

      not (is_binary(id) and id != "") ->
        {:error, :bad_header}

      not (is_binary(cwd) and cwd != "" and Path.type(cwd) == :absolute) ->
        {:error, :bad_header}

      not (is_nil(leaf) or (is_binary(leaf) and leaf != "")) ->
        {:error, :bad_header}

      true ->
        {:ok, %{id: id, cwd: cwd, leaf: leaf}}
    end
  end

  defp decode_header(_header), do: {:error, :bad_header}

  defp validate_expected_cwd(_stored_cwd, nil), do: :ok

  defp validate_expected_cwd(stored_cwd, expected_cwd) when is_binary(expected_cwd) do
    if stored_cwd == Path.expand(expected_cwd), do: :ok, else: {:error, :cwd_mismatch}
  end

  defp validate_expected_cwd(_stored_cwd, _expected_cwd), do: {:error, :cwd_mismatch}

  defp decode_entries(lines) do
    last_index = length(lines) - 1

    lines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}, [], false}, fn
      {line, index}, {:ok, entries, order, false} ->
        case decode_entry_line(line) do
          {:ok, %Entry{id: id} = entry} ->
            if Map.has_key?(entries, id) do
              {:halt, {:error, {:duplicate_id, id}}}
            else
              {:cont, {:ok, Map.put(entries, id, entry), order ++ [id], false}}
            end

          {:error, :invalid_json} when index == last_index and line != "" ->
            {:halt, {:ok, entries, order, true}}

          {:error, reason} ->
            {:halt, {:error, {:malformed_line, index + 2, reason}}}
        end
    end)
  end

  defp recover_leaf(leaf, entries, order, true) do
    if Map.has_key?(entries, leaf), do: leaf, else: List.last(order)
  end

  defp recover_leaf(leaf, _entries, _order, false), do: leaf

  defp decode_entry_line(line) do
    case JSON.decode(line) do
      {:ok, encoded} -> decode_entry(encoded)
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp decode_entry(encoded) when is_map(encoded) do
    payload_keys = Enum.filter(["user", "assistant", "toolResult"], &Map.has_key?(encoded, &1))

    with [payload_key] <- payload_keys,
         true <- map_size(encoded) == 4,
         id when is_binary(id) and id != "" <- Map.get(encoded, "id"),
         true <- Map.has_key?(encoded, "parentId"),
         parent_id when is_nil(parent_id) or (is_binary(parent_id) and parent_id != "") <-
           Map.get(encoded, "parentId"),
         timestamp when is_integer(timestamp) <- Map.get(encoded, "timestamp"),
         {:ok, message} <- decode_message(%{payload_key => Map.fetch!(encoded, payload_key)}) do
      {:ok, %Entry{id: id, parent_id: parent_id, timestamp: timestamp, message: message}}
    else
      _ -> {:error, :invalid_entry}
    end
  end

  defp decode_entry(_encoded), do: {:error, :invalid_entry}

  defp validate_tree(entries, leaf) when map_size(entries) == 0 do
    if is_nil(leaf), do: :ok, else: {:error, :missing_leaf}
  end

  defp validate_tree(entries, leaf) do
    cond do
      is_nil(leaf) or not Map.has_key?(entries, leaf) ->
        {:error, :missing_leaf}

      missing_parent = missing_parent(entries) ->
        {:error, {:missing_parent, missing_parent}}

      cycle = cycle(entries) ->
        {:error, {:cycle, cycle}}

      disconnected = disconnected_entry(entries, leaf) ->
        {:error, {:disconnected_tree, disconnected}}

      Enum.any?(entries, fn {_id, entry} -> entry.parent_id == leaf end) ->
        {:error, :leaf_not_tip}

      true ->
        :ok
    end
  end

  defp missing_parent(entries) do
    Enum.find_value(entries, fn
      {_id, %Entry{parent_id: nil}} ->
        nil

      {_id, %Entry{parent_id: parent_id}} ->
        if Map.has_key?(entries, parent_id), do: nil, else: parent_id
    end)
  end

  defp cycle(entries) do
    Enum.find(Map.keys(entries), &cycle_from?(&1, entries, MapSet.new()))
  end

  defp cycle_from?(nil, _entries, _seen), do: false

  defp cycle_from?(id, entries, seen) do
    if MapSet.member?(seen, id) do
      true
    else
      parent_id = Map.fetch!(entries, id).parent_id
      cycle_from?(parent_id, entries, MapSet.put(seen, id))
    end
  end

  defp disconnected_entry(entries, leaf) do
    selected_root = root_id(leaf, entries)
    Enum.find(Map.keys(entries), &(root_id(&1, entries) != selected_root))
  end

  defp root_id(id, entries) do
    case Map.fetch!(entries, id).parent_id do
      nil -> id
      parent_id -> root_id(parent_id, entries)
    end
  end

  defp walk_to_root(nil, _entries, messages), do: messages

  defp walk_to_root(id, entries, messages) do
    entry = Map.fetch!(entries, id)
    walk_to_root(entry.parent_id, entries, [entry.message | messages])
  end

  defp derive_interrupted_results(history) do
    {trailing_results, rest} =
      history
      |> Enum.reverse()
      |> Enum.split_while(&is_struct(&1, ToolResult))

    case rest do
      [%Assistant{tool_calls: calls} | _] when calls != [] ->
        completed =
          trailing_results
          |> Enum.map(& &1.call_id)
          |> MapSet.new()

        interrupted =
          calls
          |> Enum.reject(&MapSet.member?(completed, &1.id))
          |> Enum.map(&Message.tool_result(&1, {:error, "interrupted"}))

        history ++ interrupted

      _ ->
        history
    end
  end

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

  defp decode_outcome(%{"ok" => text} = encoded)
       when map_size(encoded) == 1 and is_binary(text),
       do: {:ok, {:ok, text}}

  defp decode_outcome(%{"error" => text} = encoded)
       when map_size(encoded) == 1 and is_binary(text),
       do: {:ok, {:error, text}}

  defp decode_outcome(_encoded), do: {:error, :invalid_message}

  defp generate_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
