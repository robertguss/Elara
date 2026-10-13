defmodule Elara.Tools.Search do
  @moduledoc "Fenced, bounded file search delegated to ripgrep; not an OS sandbox."

  alias Elara.Exec
  alias Elara.Tool.Ctx
  alias Elara.Tools.FileFence

  @default_glob_limit 200
  @default_grep_limit 100
  @max_limit 1_000
  @max_columns 400
  @max_file_list_bytes 8 * 1_024 * 1_024
  @batch_files 128

  # Listed after a caller's include pattern so an exclusion always wins.
  @excluded_dirs [".git", ".hg", ".svn", "_build", "deps", "node_modules", "target"]

  @missing_ripgrep "search requires the ripgrep executable (rg) on PATH; " <>
                     "install ripgrep (https://github.com/BurntSushi/ripgrep#installation) " <>
                     "or configure :elara, :ripgrep_path. Elara has no fallback matcher, so " <>
                     "grep and glob cannot answer differently on different hosts."

  @spec glob(map(), Ctx.t()) :: Elara.Tool.outcome()
  def glob(%{"pattern" => pattern} = args, %Ctx{} = ctx) when is_binary(pattern) do
    deadline = deadline(ctx)

    with {:ok, pattern} <- nonempty_pattern(pattern),
         {:ok, limit} <- limit_arg(args, @default_glob_limit),
         {:ok, scope} <- scope_arg(args, ctx.cwd),
         {:ok, rg} <- ripgrep(),
         {:ok, files} <- files(rg, scope, pattern, ctx, deadline, limit + 1) do
      render(Enum.join(files, "\n"), ctx, limit, "files", false)
    end
  end

  def glob(_args, _ctx), do: {:error, "glob requires pattern"}

  @spec grep(map(), Ctx.t()) :: Elara.Tool.outcome()
  def grep(%{"pattern" => pattern} = args, %Ctx{} = ctx) when is_binary(pattern) do
    deadline = deadline(ctx)

    with {:ok, pattern} <- nonempty_pattern(pattern),
         {:ok, limit} <- limit_arg(args, @default_grep_limit),
         {:ok, scope} <- scope_arg(args, ctx.cwd),
         {:ok, include} <- string_arg(args, "glob"),
         {:ok, insensitive} <- boolean_arg(args, "case_insensitive"),
         {:ok, rg} <- ripgrep(),
         {:ok, files} <- files(rg, scope, include, ctx, deadline) do
      argv =
        [
          rg,
          "--color=never",
          "--sort=path",
          "--line-number",
          "--with-filename",
          "--null",
          "--no-heading",
          "--max-columns=#{@max_columns}",
          "--max-columns-preview"
        ] ++
          case_flag(insensitive) ++
          ["--regexp", pattern]

      with {:ok, output, capped} <- grep_batches(argv, files, ctx, deadline) do
        render(output, ctx, limit, "matches", capped)
      end
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

  defp operand(paths) do
    [
      "--"
      | Enum.map(paths, fn
          "-" -> "./-"
          path -> path
        end)
    ]
  end

  # Enumerate names only, then authorize every resolved target before rg can
  # read contents. NUL framing keeps unusual filenames from bypassing the fence.
  defp files(rg, scope, include, ctx, deadline, max_files \\ nil) do
    argv =
      [rg, "--files", "--null"] ++ include_flag(include) ++ shared_flags() ++ operand([scope])

    with {:ok, fence} <- FileFence.prepare(ctx.cwd),
         {:ok, output, false} <- execute(argv, ctx, @max_file_list_bytes, deadline) do
      candidates =
        output
        |> String.split(<<0>>, trim: true)
        |> Stream.flat_map(fn path ->
          case FileFence.resolve(path, fence) do
            {:ok, {_root, resolved}} -> [Path.relative_to(resolved, Path.expand(ctx.cwd))]
            {:error, _} -> []
          end
        end)
        |> Stream.uniq()

      files = if max_files, do: Enum.take(candidates, max_files), else: Enum.to_list(candidates)
      files = Enum.sort(files)

      if System.monotonic_time(:millisecond) < deadline,
        do: {:ok, files},
        else: {:error, "search timed_out before returning results"}
    else
      {:ok, _output, true} ->
        {:error, "search file listing exceeded the 8 MiB cap; narrow the path"}

      {:error, _} = error ->
        error
    end
  end

  defp grep_batches(argv, [], ctx, deadline) do
    # Explicit empty stdin validates the regex without falling back to cwd.
    execute(argv ++ ["--", "-"], ctx, ctx.max_output_bytes || 16_384, deadline)
  end

  defp grep_batches(argv, files, ctx, deadline) do
    files
    |> Enum.chunk_every(@batch_files)
    |> Enum.reduce_while({:ok, "", false}, fn batch, {:ok, output, false} ->
      remaining = (ctx.max_output_bytes || 16_384) - byte_size(output)

      if remaining <= 0 do
        {:halt, {:ok, output, true}}
      else
        case execute(argv ++ operand(batch), ctx, remaining, deadline) do
          {:ok, next, true} -> {:halt, {:ok, output <> match_lines(next), true}}
          {:ok, next, false} -> {:cont, {:ok, output <> match_lines(next), false}}
          {:error, _} = error -> {:halt, error}
        end
      end
    end)
  end

  # Explicit file operands make rg report binary matches. Keep only numbered
  # text matches; NUL frames filenames even with colons or newlines. Incomplete
  # records at a byte cap are omitted, never presented as complete lines.
  defp match_lines(output) do
    Regex.scan(~r/([^\x00]+)\x00([^\n]*\n)/, output, capture: :all_but_first)
    |> Enum.flat_map(fn [path, text] ->
      path = if path == "./-", do: "-", else: path
      if Regex.match?(~r/^\d+:/, text), do: [path <> ":" <> text], else: []
    end)
    |> Enum.join()
  end

  defp deadline(ctx), do: System.monotonic_time(:millisecond) + (ctx.timeout_ms || 30_000)

  defp execute(argv, ctx, max_bytes, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0,
      do: execute_with_timeout(argv, ctx, max_bytes, remaining),
      else: {:error, "search timed_out before returning results"}
  end

  defp execute_with_timeout(argv, ctx, max_bytes, timeout_ms) do
    result =
      Exec.run(argv,
        cwd: ctx.cwd,
        # An empty value makes ripgrep ignore any user config file, so a host's
        # own ripgrep preferences cannot change what the model is told.
        env: %{"RIPGREP_CONFIG_PATH" => ""},
        max_bytes: max_bytes,
        timeout_ms: timeout_ms
      )

    case result do
      {:ok, %Exec.Result{termination: :exited, code: 0, output: output}} ->
        {:ok, output, false}

      {:ok, %Exec.Result{termination: :exited, code: 1}} ->
        {:ok, "", false}

      # Exit 2 covers an unusable pattern and a scope ripgrep could not read.
      # Report its diagnostic rather than presenting a partial scan as complete.
      {:ok, %Exec.Result{termination: :exited, code: code, output: output}}
      when is_integer(code) ->
        {:error, "search failed (exit #{code})\n" <> output}

      {:ok, %Exec.Result{termination: :exited, signal: signal, output: output}} ->
        {:error, "search killed by signal #{signal}\n" <> output}

      {:ok, %Exec.Result{termination: :truncated} = truncated} ->
        {:ok, truncated.output, true}

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

  defp render("", _ctx, _limit, noun, false), do: {:ok, "no #{noun}"}

  defp render(output, ctx, limit, noun, capped) do
    max_bytes = ctx.max_output_bytes || 16_384
    clipped = byte_size(output) > max_bytes
    output = if clipped, do: binary_part(output, 0, max_bytes), else: output
    {:ok, bound(output, limit, noun, capped or clipped)}
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
      :error -> resolve_scope(".", cwd)
      {:ok, path} when is_binary(path) -> resolve_scope(path, cwd)
      {:ok, _value} -> {:error, "search path must be a string"}
    end
  end

  defp resolve_scope(path, cwd) do
    with {:ok, {_root, resolved}} <- FileFence.resolve(path, cwd) do
      if File.exists?(resolved),
        do: {:ok, Path.relative_to(resolved, Path.expand(cwd))},
        else: {:error, "search path does not exist in the workspace: #{path}"}
    end
  end
end
