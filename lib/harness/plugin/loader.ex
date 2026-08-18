defmodule Harness.Plugin.Loader do
  @moduledoc false

  alias Harness.Plugin.ToolSpec

  defmodule Candidate do
    @moduledoc false
    @type t :: %__MODULE__{
            module: module(),
            metadata: Harness.Plugin.metadata(),
            tools: [Harness.Plugin.ToolSpec.t()],
            path: String.t()
          }
    defstruct [:module, :metadata, :tools, :path]
  end

  @required_callbacks [metadata: 0, tools: 0, init: 1, handle_tool: 4]

  @spec load(String.t()) :: {:ok, Candidate.t()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, source} <- File.read(path),
         {:ok, quoted} <- parse(source, path),
         {:ok, source_module, body, meta} <- plugin_module(quoted),
         :ok <- validate_body(body, source_module),
         generated_module = generated_module(source_module, source, path),
         {:ok, module} <- compile(generated_module, body, meta, path),
         {:ok, metadata, tools} <- validate_contract(module) do
      {:ok, %Candidate{module: module, metadata: metadata, tools: tools, path: path}}
    end
  end

  @spec call(module(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  def call(module, function, args) do
    try do
      {:ok, apply(module, function, args)}
    rescue
      error -> {:error, {:callback_crashed, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:callback_crashed, {kind, reason}}}
    end
  end

  defp parse(source, path) do
    case Code.string_to_quoted(source, file: path, columns: true) do
      {:ok, quoted} -> {:ok, quoted}
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  defp plugin_module({:__block__, _, [quoted]}), do: plugin_module(quoted)

  defp plugin_module({:defmodule, meta, [name, [do: body]]}) do
    case literal_module(name) do
      {:ok, module} -> {:ok, module, body, meta}
      :error -> {:error, :plugin_module_must_have_a_literal_name}
    end
  end

  defp plugin_module(_quoted), do: {:error, :plugin_file_must_define_exactly_one_module}

  defp literal_module({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: {:ok, Module.concat(parts)}, else: :error
  end

  defp literal_module(module) when is_atom(module), do: {:ok, module}
  defp literal_module(_name), do: :error

  defp validate_body(body, source_module) do
    {_body, flags} =
      Macro.prewalk(body, %{nested_module?: false, literal_self?: false}, fn
        {:defmodule, _, _} = node, flags ->
          {node, %{flags | nested_module?: true}}

        {:__aliases__, _, parts} = node, flags ->
          literal_self? = Enum.all?(parts, &is_atom/1) and Module.concat(parts) == source_module
          {node, %{flags | literal_self?: flags.literal_self? or literal_self?}}

        node, flags ->
          {node, flags}
      end)

    cond do
      flags.nested_module? -> {:error, :nested_modules_are_not_supported}
      flags.literal_self? -> {:error, :use_dunder_module_for_plugin_self_references}
      true -> :ok
    end
  end

  defp generated_module(source_module, source, path) do
    source_name =
      source_module
      |> Atom.to_string()
      |> String.trim_leading("Elixir.")
      |> String.replace(".", "_")

    hash = {Path.expand(path), source} |> :erlang.term_to_binary() |> :erlang.md5()
    hash = Base.encode16(hash, case: :lower)
    Module.concat(Harness.Plugin.Loaded, "#{source_name}_V#{hash}")
  end

  defp compile(module, body, meta, path) do
    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      quoted = {:defmodule, meta, [module, [do: body]]}

      try do
        compiled = Code.compile_quoted(quoted, path)

        case compiled do
          [{^module, _bytecode}] ->
            {:ok, module}

          modules ->
            purge_modules(modules)
            {:error, :plugin_must_compile_to_exactly_one_module}
        end
      rescue
        error -> {:error, {:compile_error, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:compile_error, {kind, reason}}}
      end
    end
  end

  defp purge_modules(modules) do
    Enum.each(modules, fn {module, _bytecode} ->
      :code.purge(module)
      :code.delete(module)
    end)
  end

  defp validate_contract(module) do
    case Enum.find(@required_callbacks, fn {function, arity} ->
           not function_exported?(module, function, arity)
         end) do
      nil ->
        with {:ok, raw_metadata} <- call(module, :metadata, []),
             {:ok, metadata} <- validate_metadata(raw_metadata),
             {:ok, raw_tools} <- call(module, :tools, []),
             {:ok, tools} <- validate_tools(raw_tools) do
          {:ok, metadata, tools}
        end

      callback ->
        {:error, {:missing_callback, callback}}
    end
  end

  defp validate_metadata(%{id: id, version: version} = metadata)
       when is_binary(id) and id != "" and is_binary(version) and version != "" and
              map_size(metadata) == 2 do
    {:ok, metadata}
  end

  defp validate_metadata(_metadata), do: {:error, :invalid_metadata}

  defp validate_tools(tools) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, MapSet.new(), []}, fn
      %ToolSpec{name: name, description: description, parameters: parameters} = tool,
      {:ok, names, acc}
      when is_binary(name) and name != "" and is_binary(description) and is_map(parameters) ->
        if MapSet.member?(names, name) do
          {:halt, {:error, {:duplicate_plugin_tool, name}}}
        else
          {:cont, {:ok, MapSet.put(names, name), [tool | acc]}}
        end

      _tool, _acc ->
        {:halt, {:error, :invalid_plugin_tool}}
    end)
    |> case do
      {:ok, _names, validated} -> {:ok, Enum.reverse(validated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_tools(_tools), do: {:error, :invalid_plugin_tools}
end
