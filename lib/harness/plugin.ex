defmodule Harness.Plugin do
  @moduledoc """
  Contract for trusted local source plugins.

  Plugin implementation modules are immutable, content-addressed revisions.
  Mutable state belongs to a `Harness.Plugin.Server` that survives reloads.
  """

  alias Harness.Plugin.Server
  alias Harness.Tool.Ctx
  alias Harness.Tool.PluginRef

  defmodule ToolSpec do
    @moduledoc "A tool exposed by a plugin."

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            parameters: map()
          }

    defstruct [:name, :description, :parameters]
  end

  defmodule Info do
    @moduledoc "A loaded plugin instance."

    @type t :: %__MODULE__{
            id: String.t(),
            version: String.t(),
            generation: pos_integer(),
            path: String.t(),
            module: module(),
            pid: pid()
          }

    defstruct [:id, :version, :generation, :path, :module, :pid]
  end

  @type metadata :: %{id: String.t(), version: String.t()}

  @callback metadata() :: metadata()
  @callback tools() :: [ToolSpec.t()]
  @callback init(Ctx.t()) :: {:ok, term()} | {:error, term()}
  @callback handle_tool(String.t(), map(), Ctx.t(), term()) ::
              {Harness.Tool.outcome(), term()}
  @callback migrate(old_state :: term(), old_metadata :: metadata()) ::
              {:ok, term()} | {:error, term()}

  @optional_callbacks migrate: 2

  @spec discover(String.t()) :: [String.t()]
  def discover(cwd) when is_binary(cwd) do
    cwd
    |> Path.join(".harness/plugins/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @doc false
  @spec run(map(), Ctx.t()) :: Harness.Tool.outcome()
  def run(args, %Ctx{plugin: %PluginRef{} = plugin, tool_name: tool_name} = ctx)
      when is_map(args) and is_binary(tool_name) do
    clean_ctx = %{ctx | plugin: nil, tool_name: nil}
    Server.run(plugin.server, plugin.generation, tool_name, args, clean_ctx)
  end

  def run(_args, _ctx), do: {:error, "invalid plugin tool context"}
end
