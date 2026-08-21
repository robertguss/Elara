defmodule Harness.Plugin do
  @moduledoc """
  Contract for trusted local source plugins.

  Plugin implementation modules are immutable, content-addressed revisions.
  Mutable state belongs to a `Harness.Plugin.Server` that survives reloads.
  """

  alias Harness.Tool.Ctx

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
  @spec invoke(module(), String.t(), map(), Ctx.t(), term()) ::
          {:commit, Harness.Tool.outcome(), term()} | {:abort, Harness.Tool.outcome()}
  def invoke(module, tool_name, args, %Ctx{} = ctx, plugin_state)
      when is_atom(module) and is_binary(tool_name) and is_map(args) do
    case apply(module, :handle_tool, [tool_name, args, ctx, plugin_state]) do
      {{kind, text} = outcome, new_state}
      when kind in [:ok, :error, :indeterminate] and is_binary(text) ->
        {:commit, outcome, new_state}

      _other ->
        {:abort, {:error, "plugin returned an invalid tool result"}}
    end
  end

  @doc false
  @spec run(map(), Ctx.t()) :: Harness.Tool.outcome()
  def run(_args, %Ctx{}), do: {:error, "plugin tool requires a session lease"}
end
