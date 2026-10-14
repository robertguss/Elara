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
            session_id: String.t() | nil,
            output_owner: String.t() | nil,
            fnox_config: map() | nil,
            cwd: String.t(),
            plugin: PluginRef.t() | nil,
            tool_name: String.t() | nil,
            job_id: String.t() | nil,
            operation_digest: String.t() | nil,
            max_output_bytes: pos_integer() | nil,
            timeout_ms: pos_integer() | nil
          }
    defstruct [
      :session_id,
      :output_owner,
      :fnox_config,
      :cwd,
      :plugin,
      :tool_name,
      :job_id,
      :operation_digest,
      :max_output_bytes,
      :timeout_ms
    ]
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
          mutating: boolean(),
          cancel_on_interrupt: boolean()
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
    mutating: false,
    cancel_on_interrupt: false
  ]

  @spec builtins() :: [t()]
  def builtins do
    [
      read_tool(),
      write_tool(),
      edit_tool(),
      bash_tool(),
      output_read_tool(),
      web_fetch_tool(),
      grep_tool(),
      glob_tool(),
      Elara.Skills.tool(),
      Elara.Threads.tool(),
      Elara.TestJobs.tool(),
      Elara.Jobs.tool(),
      Elara.Completion.tool()
    ] ++ Elara.Threads.Communication.tools()
  end

  @doc false
  @spec builtin_write?(t()) :: boolean()
  def builtin_write?(%__MODULE__{} = tool) do
    tool.name == "write" and tool.version == "1" and tool.run == {Elara.Tools, :write} and
      tool.plugin == nil and tool.capabilities == ["filesystem:write"] and
      tool.placement == :any and tool.mutating
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
      version: "3",
      description:
        "Read a file relative to the working directory, optionally with one-based offset, line limit, and line numbers.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to read"},
          "offset" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "Optional one-based line offset; defaults to 1 when ranged"
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "Optional positive line limit; defaults to 200 when ranged"
          },
          "line_numbers" => %{
            "type" => "boolean",
            "description" =>
              "Prefix selected logical lines with original one-based line numbers; defaults to false"
          }
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
      version: "2",
      description:
        "Replace exactly one occurrence of old_text with new_text in a file, or all occurrences when replace_all is true.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to edit"},
          "old_text" => %{"type" => "string", "description" => "Exact text to find"},
          "new_text" => %{"type" => "string", "description" => "Replacement text"},
          "replace_all" => %{
            "type" => "boolean",
            "description" => "Replace every non-overlapping occurrence; defaults to false"
          }
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
      version: "2",
      description:
        "Run a local shell command in the working directory. stdout and stderr are merged, retained privately, and previewed with an output_read handle.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "Shell command to run"},
          "timeout_ms" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" =>
              "Per-call timeout in milliseconds. Session default and ceiling apply; unless overridden, 600000 (10 minutes) and 3600000 (60 minutes)."
          }
        },
        "required" => ["command"]
      },
      capabilities: ["shell"],
      placement: :local,
      mutating: true,
      run: {Elara.Tools, :bash}
    }
  end

  defp output_read_tool do
    %__MODULE__{
      name: "output_read",
      description:
        "Read this session's retained output by opaque handle. One-based line offset defaults to 1; limit defaults to 100 (maximum 200). Optional pattern is a literal, not a regex. Long lines are explicitly clipped; literal reads show the matching snippet.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "handle" => %{"type" => "string"},
          "offset" => %{"type" => "integer", "minimum" => 1},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 200},
          "pattern" => %{"type" => "string", "minLength" => 1}
        },
        "required" => ["handle"]
      },
      capabilities: ["filesystem:read"],
      placement: :local,
      cancel_on_interrupt: true,
      run: {Elara.Tools, :output_read}
    }
  end

  @search_scope "Read-only, fenced to the working directory and operator-approved roots; " <>
                  "protected files and escaping symlinks are skipped or refused. Honours .gitignore, " <>
                  "skips VCS and build directories, orders results deterministically, " <>
                  "and bounds them with a truncation notice. Requires ripgrep."

  defp web_fetch_tool do
    %__MODULE__{
      name: "web_fetch",
      description:
        "GET a public http(s) page without cookies or credentials. HTML becomes Markdown. Returns labeled untrusted content, a heading outline and about 6 KiB; the full page is retained behind output_read. Private destinations and unsafe redirects are refused. Not a browser or a sandbox.",
      parameters: %{
        "type" => "object",
        "properties" => %{"url" => %{"type" => "string"}},
        "required" => ["url"],
        "additionalProperties" => false
      },
      capabilities: ["network:web"],
      placement: :local,
      cancel_on_interrupt: true,
      run: {Elara.WebFetch, :run}
    }
  end

  defp grep_tool do
    %__MODULE__{
      name: "grep",
      description:
        "Search workspace file contents for a regular expression, returning path:line:text per match. " <>
          @search_scope,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Rust-syntax regular expression to search for"
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "Optional file or directory inside the workspace or an operator-approved root; defaults to the whole workspace"
          },
          "glob" => %{
            "type" => "string",
            "description" => "Optional path glob limiting which files are searched, e.g. **/*.ex"
          },
          "case_insensitive" => %{
            "type" => "boolean",
            "description" => "Match regardless of case; defaults to false"
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 1000,
            "description" => "Maximum matching lines to return; defaults to 100"
          }
        },
        "required" => ["pattern"]
      },
      capabilities: ["filesystem:read"],
      run: {Elara.Tools.Search, :grep}
    }
  end

  defp glob_tool do
    %__MODULE__{
      name: "glob",
      description:
        "List workspace files whose path matches a glob pattern, one path per line. " <>
          @search_scope,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Path glob to match, e.g. **/*.ex or lib/**/tool*.ex"
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "Optional file or directory inside the workspace or an operator-approved root; defaults to the whole workspace"
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 1000,
            "description" => "Maximum paths to return; defaults to 200"
          }
        },
        "required" => ["pattern"]
      },
      capabilities: ["filesystem:read"],
      run: {Elara.Tools.Search, :glob}
    }
  end
end
