defmodule Elara.Tool do
  @moduledoc "Tool values. run is MFA data, never a closure."

  defmodule PluginRef do
    @moduledoc false
    @type t :: %__MODULE__{
            id: String.t(),
            version: String.t(),
            generation: pos_integer(),
            server: pid()
          }
    defstruct [:id, :version, :generation, :server]
  end

  defmodule Ctx do
    @type t :: %__MODULE__{
            cwd: String.t(),
            plugin: PluginRef.t() | nil,
            tool_name: String.t() | nil
          }
    defstruct [:cwd, :plugin, :tool_name]
  end

  @type outcome :: {:ok, String.t()} | {:error, String.t()} | {:indeterminate, String.t()}

  @typedoc """
  parameters is a raw JSON Schema map, passed to the provider as is.
  run points at f(args :: map(), ctx :: Ctx.t()) :: outcome().
  """
  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          parameters: map(),
          run: {module(), atom()},
          plugin: PluginRef.t() | nil,
          capabilities: [String.t()],
          placement: :local | :remote | :any,
          mutating: boolean()
        }
  defstruct [
    :name,
    :description,
    :parameters,
    :run,
    :plugin,
    version: "1",
    capabilities: [],
    placement: :any,
    mutating: false
  ]

  @spec builtins() :: [t()]
  def builtins do
    [
      read_tool(),
      write_tool(),
      edit_tool(),
      bash_tool()
    ]
  end

  @doc "Table keyed by name. Duplicate names are an ArgumentError at session start."
  @spec table([t()]) :: %{String.t() => t()}
  def table(tools) when is_list(tools) do
    Enum.reduce(tools, %{}, fn
      %__MODULE__{name: name} = _tool, acc when is_map_key(acc, name) ->
        raise ArgumentError, "duplicate tool name: #{name}"

      %__MODULE__{name: name} = tool, acc ->
        Map.put(acc, name, tool)
    end)
  end

  defp read_tool do
    %__MODULE__{
      name: "read",
      description: "Read a file relative to the working directory.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to read"}
        },
        "required" => ["path"]
      },
      capabilities: ["filesystem:read"],
      run: {Elara.Tools, :read}
    }
  end

  defp write_tool do
    %__MODULE__{
      name: "write",
      description: "Write contents to a file, creating parent directories as needed.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to write"},
          "content" => %{"type" => "string", "description" => "File contents"}
        },
        "required" => ["path", "content"]
      },
      capabilities: ["filesystem:write"],
      mutating: true,
      run: {Elara.Tools, :write}
    }
  end

  defp edit_tool do
    %__MODULE__{
      name: "edit",
      description: "Replace exactly one occurrence of old_text with new_text in a file.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to edit"},
          "old_text" => %{"type" => "string", "description" => "Exact text to find once"},
          "new_text" => %{"type" => "string", "description" => "Replacement text"}
        },
        "required" => ["path", "old_text", "new_text"]
      },
      capabilities: ["filesystem:read", "filesystem:write"],
      mutating: true,
      run: {Elara.Tools, :edit}
    }
  end

  defp bash_tool do
    %__MODULE__{
      name: "bash",
      description: "Run a shell command in the working directory. stdout and stderr are merged.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "Shell command to run"}
        },
        "required" => ["command"]
      },
      capabilities: ["shell"],
      mutating: true,
      run: {Elara.Tools, :bash}
    }
  end
end
