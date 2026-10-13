defmodule Elara.MCP.Config do
  @moduledoc "Inert MCP configuration snapshots; only internal reads access operator files."

  defstruct [:name, :path, :sha256, :cwd, :transport, :command, :args, :env, :url, :token_env]

  @max_bytes 1_048_576

  def read(cwd, name) when is_binary(cwd) and is_binary(name) do
    home = Application.get_env(:elara, :mcp_home, System.user_home!())
    paths = Enum.uniq([Path.join(home, ".elara/mcp.json"), Path.join(cwd, ".elara/mcp.json")])

    with {:ok, servers} <- load(paths) do
      case Map.fetch(servers, name) do
        {:ok, config} -> {:ok, config}
        :error -> {:error, "MCP server #{inspect(name)} is not configured"}
      end
    end
  end

  defp load(paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, all} ->
      with {:ok, entries} <- read_file(Path.expand(path)),
           :ok <- no_clash(all, entries) do
        {:cont, {:ok, Map.merge(all, entries)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp read_file(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:ok, bytes} when byte_size(bytes) <= @max_bytes ->
        case JSON.decode(bytes) do
          {:ok, %{"servers" => servers} = root} when map_size(root) == 1 and is_map(servers) ->
            Enum.reduce_while(servers, {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
              case parse(name, spec, path, bytes) do
                {:ok, config} -> {:cont, {:ok, Map.put(acc, name, config)}}
                error -> {:halt, error}
              end
            end)

          _ ->
            invalid(path)
        end

      _ ->
        invalid(path)
    end
  end

  defp no_clash(all, entries) do
    case Enum.find(Map.keys(entries), &Map.has_key?(all, &1)) do
      nil ->
        :ok

      name ->
        {:error,
         "MCP name #{inspect(name)} occurs in both #{all[name].path} and #{entries[name].path}"}
    end
  end

  defp parse(name, %{"transport" => "stdio", "command" => command} = spec, path, bytes)
       when is_binary(name) and name != "" and is_binary(command) do
    args = Map.get(spec, "args", [])
    env = Map.get(spec, "env", %{})

    if Map.keys(spec) -- ~w(transport command args env) == [] and
         Path.type(command) == :absolute and text?(command) and is_list(args) and
         Enum.all?(args, &text?/1) and is_map(env) and
         Enum.all?(env, fn {key, value} -> env_name?(key) and env_name?(value) end) do
      {:ok,
       %__MODULE__{
         name: name,
         path: path,
         sha256: digest(bytes),
         cwd: Path.dirname(Path.dirname(path)),
         transport: :stdio,
         command: command,
         args: args,
         env: env
       }}
    else
      invalid(path)
    end
  end

  defp parse(name, %{"transport" => "http", "url" => url} = spec, path, bytes)
       when is_binary(name) and name != "" and is_binary(url) do
    uri = URI.parse(url)
    token = Map.get(spec, "token_env")

    if Map.keys(spec) -- ~w(transport url token_env) == [] and text?(url) and
         uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         uri.userinfo == nil and uri.fragment == nil and (token == nil or env_name?(token)) do
      {:ok,
       %__MODULE__{
         name: name,
         path: path,
         sha256: digest(bytes),
         transport: :http,
         url: url,
         token_env: token
       }}
    else
      invalid(path)
    end
  end

  defp parse(_name, _spec, path, _bytes), do: invalid(path)
  defp invalid(path), do: {:error, "invalid or unreadable MCP config: #{path}"}

  defp text?(value),
    do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)

  defp env_name?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, value)

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
