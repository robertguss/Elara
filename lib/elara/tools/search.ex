defmodule Elara.Tools.Search do
  @moduledoc """
  Read-only workspace search delegated to ripgrep. Bounded and deterministic.
  Scoped lexically to the session workspace, like the rest of relative path
  handling; not a filesystem boundary. Nothing mutates, so an incomplete search
  is an error or a labelled truncation, never `indeterminate`.
  """

  alias Elara.Effect.AtomicFile
  alias Elara.Exec
  alias Elara.Tool.Ctx

  @default_glob_limit 200
  @default_grep_limit 100
  @max_limit 1_000
  @max_columns 400

  # Listed after a caller's include pattern so an exclusion always wins.
  @excluded_dirs [".git", ".hg", ".svn", "_build", "deps", "node_modules", "target"]

  @missing_ripgrep "search requires the ripgrep executable (rg) on PATH; " <>
                     "install ripgrep (https://github.com/BurntSushi/ripgrep#installation) " <>
                     "or configure :elara, :ripgrep_path. Elara has no fallback matcher, so " <>
                     "grep and glob cannot answer differently on different hosts."

  @spec glob(map(), Ctx.t()) :: Elara.Tool.outcome()
  def glob(%{"pattern" => pattern} = args, %Ctx{} = ctx) when is_binary(pattern) do
    with {:ok, pattern} <- nonempty_pattern(pattern),
         {:ok, limit} <- limit_arg(args, @default_glob_limit),
         {:ok, scope} <- scope_arg(args, ctx.cwd),
         {:ok, rg} <- ripgrep() do
      argv =
        [rg, "--files", "--glob", pattern] ++ shared_flags() ++ operand(scope)

      run(argv, ctx, limit, "files")
    end
  end

  def glob(_args, _ctx), do: {:error, "glob requires pattern"}

  @spec grep(map(), Ctx.t()) :: Elara.Tool.outcome()
  def grep(%{"pattern" => pattern} = args, %Ctx{} = ctx) when is_binary(pattern) do
    with {:ok, pattern} <- nonempty_pattern(pattern),
         {:ok, limit} <- limit_arg(args, @default_grep_limit),
         {:ok, scope} <- scope_arg(args, ctx.cwd),
         {:ok, include} <- string_arg(args, "glob"),
         {:ok, insensitive} <- boolean_arg(args, "case_insensitive"),
         {:ok, rg} <- ripgrep() do
      argv =
        [
          rg,
          "--line-number",
          "--with-filename",
          "--no-heading",
          "--max-columns=#{@max_columns}",
          "--max-columns-preview"
        ] ++
          case_flag(insensitive) ++
          include_flag(include) ++
          shared_flags() ++
          ["--regexp", pattern] ++
          operand(scope)

      run(argv, ctx, limit, "matches")
    end
  end

  def grep(_args, _ctx), do: {:error, "grep requires pattern"}

  # --sort=path trades ripgrep's parallel traversal for a deterministic order.
  # --no-require-git honours .gitignore whether or not the workspace is a checkout.
  defp shared_flags do
    ["--sort=path", "--no-require-git", "--hidden", "--color=never"] ++
      Enum.flat_map(@excluded_dirs, &["--glob", "!" <> &1])
  end

  defp case_flag(true), do: ["--ignore-case"]
  defp case_flag(false), do: []

  defp include_flag(nil), do: []
  defp include_flag(glob), do: ["--glob", glob]

  defp operand(nil), do: []
  defp operand(path), do: ["--", path]

  defp run(argv, %Ctx{} = ctx, limit, noun) do
    result =
      Exec.run(argv,
        cwd: ctx.cwd,
        # An empty value makes ripgrep ignore any user config file, so a host's
        # own ripgrep preferences cannot change what the model is told.
        env: %{"RIPGREP_CONFIG_PATH" => ""},
        max_bytes: ctx.max_output_bytes || 16_384,
        timeout_ms: ctx.timeout_ms || 30_000
      )

    case result do
      {:ok, %Exec.Result{termination: :exited, code: 0, output: output}} ->
        {:ok, bound(output, limit, noun, false)}

      {:ok, %Exec.Result{termination: :exited, code: 1}} ->
        {:ok, "no #{noun}"}

      # Exit 2 covers an unusable pattern and a scope ripgrep could not read.
      # Report its diagnostic rather than presenting a partial scan as complete.
      {:ok, %Exec.Result{termination: :exited, code: code, output: output}}
      when is_integer(code) ->
        {:error, "search failed (exit #{code})\n" <> output}

      {:ok, %Exec.Result{termination: :exited, signal: signal, output: output}} ->
        {:error, "search killed by signal #{signal}\n" <> output}

      {:ok, %Exec.Result{termination: :truncated} = truncated} ->
        {:ok, bound(truncated.output, limit, noun, true)}

      {:ok, %Exec.Result{termination: termination}} ->
        {:error, "search #{termination} before returning results"}

      {:error, {:not_started, message}} ->
        {:error, "search failed: #{message}"}

      # A lost stub leaves the search incomplete; with nothing mutated there is
      # no uncertain workspace state to report.
      {:indeterminate, message} ->
        {:error, "search failed: #{message}"}
    end
  end

  defp bound(output, limit, noun, byte_capped) do
    lines = output |> String.split("\n") |> drop_trailing(byte_capped)
    shown = Enum.take(lines, limit)

    notice =
      cond do
        length(lines) > limit ->
          ["[truncated at the #{limit}-#{noun} cap; narrow the pattern or path]"]

        byte_capped ->
          ["[truncated at the output byte cap; narrow the pattern or path]"]

        true ->
          []
      end

    Enum.join(shown ++ notice, "\n")
  end

  # A byte cap kills ripgrep mid-write, so its last line may be incomplete.
  defp drop_trailing(lines, byte_capped) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ when byte_capped -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  defp ripgrep do
    path = Application.get_env(:elara, :ripgrep_path) || System.find_executable("rg")

    if is_binary(path) and File.regular?(path),
      do: {:ok, path},
      else: {:error, @missing_ripgrep}
  end

  defp nonempty_pattern(""), do: {:error, "search pattern must not be empty"}
  defp nonempty_pattern(pattern), do: {:ok, pattern}

  defp limit_arg(args, default) do
    case Map.fetch(args, "limit") do
      :error -> {:ok, default}
      {:ok, value} when is_integer(value) and value > 0 and value <= @max_limit -> {:ok, value}
      {:ok, _value} -> {:error, "search limit must be an integer from 1 to #{@max_limit}"}
    end
  end

  defp string_arg(args, key) do
    case Map.fetch(args, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, "search #{key} must be a non-empty string"}
    end
  end

  defp boolean_arg(args, key) do
    case Map.fetch(args, key) do
      :error -> {:ok, false}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, "search #{key} must be a boolean"}
    end
  end

  defp scope_arg(args, cwd) do
    case Map.fetch(args, "path") do
      :error -> {:ok, nil}
      {:ok, path} when is_binary(path) -> resolve_scope(path, cwd)
      {:ok, _value} -> {:error, "search path must be a string"}
    end
  end

  defp resolve_scope(path, cwd) do
    trimmed = if Path.type(path) == :relative, do: String.trim_trailing(path, "/"), else: path

    if trimmed in ["", "."] do
      {:ok, nil}
    else
      confine(trimmed, cwd)
    end
  end

  # Reuses the session's existing lexical confinement rule rather than a second
  # path checker: relative, canonical, no NUL, and never above the workspace.
  defp confine(path, cwd) do
    case AtomicFile.target(path, cwd) do
      {:ok, target} ->
        if File.exists?(target.full_path),
          do: {:ok, target.path},
          else: {:error, "search path does not exist in the workspace: #{path}"}

      {:error, :path_outside_workspace} ->
        {:error, "search path must stay inside the working directory: #{path}"}
    end
  end
end
