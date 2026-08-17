defmodule Harness.Session.Store do
  @moduledoc """
  Private JSONL persistence for a linear session log.
  """

  alias Harness.Message
  alias Harness.Message.{Assistant, ToolCall, ToolResult, User}

  @version 1
  @hash_length 12

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
          path: String.t() | nil,
          messages: [Message.t()],
          persist?: boolean()
        }

  defstruct [:id, :cwd, :path, messages: [], persist?: true]

  @spec root() :: {:ok, String.t()} | {:error, :no_home}
  def root do
    case Application.get_env(:harness, :sessions_root) do
      root when is_binary(root) and root != "" ->
        {:ok, Path.expand(root)}

      _ ->
        case System.user_home() do
          home when is_binary(home) and home != "" ->
            {:ok, Path.join([home, ".harness", "sessions"])}

          _ ->
            {:error, :no_home}
        end
    end
  end

  @spec new(String.t()) :: t()
  def new(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)
    id = generate_id()
    {:ok, root} = root()

    %__MODULE__{
      id: id,
      cwd: cwd,
      path: Path.join([root, cwd_key(cwd), "#{id}.jsonl"]),
      persist?: true
    }
  end

  @spec memory(String.t()) :: t()
  def memory(cwd) when is_binary(cwd) do
    %__MODULE__{
      id: generate_id(),
      cwd: Path.expand(cwd),
      path: nil,
      persist?: false
    }
  end

  @spec open(String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def open(path, expected_cwd \\ nil) when is_binary(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, header, entry_lines} <- decode_file_lines(raw),
         :ok <- validate_expected_cwd(header.cwd, expected_cwd),
         {:ok, messages} <- decode_entries(entry_lines) do
      {:ok,
       %__MODULE__{
         id: header.id,
         cwd: header.cwd,
         path: path,
         messages: messages,
         persist?: true
       }}
    end
  end

  @spec append(t(), Message.t()) :: {:ok, t()} | {:error, term()}
  def append(%__MODULE__{} = store, message)
      when is_struct(message, User) or is_struct(message, Assistant) or
             is_struct(message, ToolResult) do
    updated = %{store | messages: store.messages ++ [message]}

    cond do
      not store.persist? ->
        {:ok, updated}

      is_nil(store.path) ->
        {:error, :no_path}

      true ->
        case persist(store, message) do
          :ok -> {:ok, updated}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec history(t()) :: [Message.t()]
  def history(%__MODULE__{} = store), do: store.messages

  @spec list(String.t()) :: [Info.t()]
  def list(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)

    case root() do
      {:error, :no_home} ->
        []

      {:ok, root} ->
        dir = Path.join(root, cwd_key(cwd))

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
  end

  @spec newest(String.t()) :: {:ok, Info.t()} | {:error, :no_session}
  def newest(cwd) when is_binary(cwd) do
    case list(cwd) do
      [info | _] -> {:ok, info}
      [] -> {:error, :no_session}
    end
  end

  @spec claim(t()) :: {:ok, t()} | {:error, :locked}
  def claim(%__MODULE__{persist?: false} = store), do: {:ok, store}
  def claim(%__MODULE__{path: nil} = store), do: {:ok, store}

  def claim(%__MODULE__{path: path} = store) when is_binary(path) do
    key = Path.expand(path)

    case Registry.lookup(Harness.SessionLocks, key) do
      [{pid, _}] when pid == self() ->
        {:ok, store}

      _ ->
        case Registry.register(Harness.SessionLocks, key, nil) do
          {:ok, _} -> {:ok, store}
          {:error, {:already_registered, _}} -> {:error, :locked}
        end
    end
  end

  @spec release(t()) :: :ok
  def release(%__MODULE__{persist?: false}), do: :ok
  def release(%__MODULE__{path: nil}), do: :ok

  def release(%__MODULE__{path: path}) when is_binary(path) do
    key = Path.expand(path)

    case Registry.lookup(Harness.SessionLocks, key) do
      [{pid, _}] when pid == self() ->
        Registry.unregister(Harness.SessionLocks, key)
        :ok

      _ ->
        :ok
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

  defp persist(store, message) do
    line = message |> encode_entry() |> JSON.encode!()

    if File.regular?(store.path) do
      File.write(store.path, line <> "\n", [:append])
    else
      write_new(store, line)
    end
  end

  defp write_new(store, line) do
    dir = Path.dirname(store.path)
    header = JSON.encode!(encode_header(store))

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(store.path, header <> "\n" <> line <> "\n"),
         :ok <- File.chmod(store.path, 0o600) do
      :ok
    end
  end

  defp encode_header(store) do
    %{
      "version" => @version,
      "id" => store.id,
      "cwd" => store.cwd
    }
  end

  defp encode_entry(message) do
    message
    |> encode_message()
    |> Map.merge(%{
      "id" => generate_id(),
      "timestamp" => System.system_time(:millisecond)
    })
  end

  defp info_for_path(path, cwd) do
    with {:ok, %{type: :regular, mtime: timestamp}} <- File.stat(path, time: :posix),
         {:ok, store} <- open(path, cwd),
         true <- Enum.any?(store.messages, &is_struct(&1, User)) do
      [%Info{path: path, id: store.id, cwd: store.cwd, timestamp: timestamp}]
    else
      _ -> []
    end
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

  defp decode_header(%{"version" => version, "id" => id, "cwd" => cwd} = header)
       when map_size(header) == 3 do
    cond do
      not is_integer(version) ->
        {:error, :bad_header}

      version != @version ->
        {:error, {:unsupported_version, version}}

      not (is_binary(id) and id != "") ->
        {:error, :bad_header}

      not (is_binary(cwd) and cwd != "" and Path.type(cwd) == :absolute) ->
        {:error, :bad_header}

      true ->
        {:ok, %{id: id, cwd: cwd}}
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
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn
      {line, index}, {:ok, messages, ids} ->
        case decode_entry_line(line) do
          {:ok, {id, message}} ->
            if MapSet.member?(ids, id) do
              {:halt, {:error, {:duplicate_id, id}}}
            else
              {:cont, {:ok, [message | messages], MapSet.put(ids, id)}}
            end

          {:error, :invalid_json} when index == last_index and line != "" ->
            {:halt, {:ok, Enum.reverse(messages)}}

          {:error, reason} ->
            {:halt, {:error, {:malformed_line, index + 2, reason}}}
        end
    end)
    |> case do
      {:ok, messages, _ids} -> {:ok, Enum.reverse(messages)}
      {:ok, messages} -> {:ok, messages}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_entry_line(line) do
    case JSON.decode(line) do
      {:ok, encoded} -> decode_entry(encoded)
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp decode_entry(encoded) when is_map(encoded) do
    payload_keys = Enum.filter(["user", "assistant", "toolResult"], &Map.has_key?(encoded, &1))

    with [payload_key] <- payload_keys,
         true <- map_size(encoded) == 3,
         id when is_binary(id) and id != "" <- Map.get(encoded, "id"),
         timestamp when is_integer(timestamp) <- Map.get(encoded, "timestamp"),
         {:ok, message} <- decode_message(%{payload_key => Map.fetch!(encoded, payload_key)}) do
      {:ok, {id, message}}
    else
      _ -> {:error, :invalid_entry}
    end
  end

  defp decode_entry(_encoded), do: {:error, :invalid_entry}

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
