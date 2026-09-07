defmodule ElixirProjectPlugin do
  @behaviour Elara.Plugin

  alias Elara.Plugin.ToolSpec
  alias Elara.CheckEvidence

  @max_output_bytes 8_000

  @impl true
  def metadata, do: %{id: "elixir_project", version: "3"}

  @impl true
  def tools do
    [
      %ToolSpec{
        name: "elixir_project_info",
        description:
          "Inspect the current Mix project. Returns its application, version, Elixir requirement, source paths, and dependencies.",
        parameters: empty_schema()
      },
      %ToolSpec{
        name: "elixir_check",
        description:
          "Run Elixir project checks with compact output. Select up to four evidence_paths before running to retain source excerpts for diagnose_check. Use 'all' before completing a code change.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "evidence_paths" => evidence_paths_schema(),
            "check" => %{
              "type" => "string",
              "enum" => ["all", "format", "compile"],
              "description" => "Check to run; defaults to all"
            }
          },
          "additionalProperties" => false
        }
      },
      %ToolSpec{
        name: "elixir_test",
        description:
          "Run the whole ExUnit suite or a focused test file/path:line. Select up to four evidence_paths to capture source before running; the focused test file is captured by default. Returns an evidence_run_id for check_evidence and diagnose_check.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "evidence_paths" => evidence_paths_schema(),
            "target" => %{
              "type" => "string",
              "description" => "Optional test file or path:line; omit to run the full suite"
            }
          },
          "additionalProperties" => false
        }
      },
      %ToolSpec{
        name: "elixir_last_run",
        description:
          "Show the last check or test run recorded by this session, useful after reloading the plugin.",
        parameters: empty_schema()
      },
      %ToolSpec{
        name: "elixir_rerun_last",
        description:
          "Repeat this session's last Mix invocation, including its focused test target, using the current project files.",
        parameters: empty_schema()
      }
    ]
  end

  @impl true
  def init(_ctx), do: {:ok, %{run_count: 0, last_run: nil}}

  @impl true
  def migrate(%{last_run: nil} = state, _metadata), do: {:ok, state}

  def migrate(%{last_run: last} = state, %{version: "1"}) do
    invocation =
      case last.command do
        "project_info" -> {"elixir_project_info", %{}}
        "check:" <> check -> {"elixir_check", %{"check" => check}}
        "test:all" -> {"elixir_test", %{}}
        "test:" <> target -> {"elixir_test", %{"target" => target}}
      end

    {:ok, %{state | last_run: Map.put(last, :invocation, invocation)}}
  end

  def migrate(state, _metadata), do: {:ok, state}

  @impl true
  def handle_tool("elixir_project_info", _args, ctx, state) do
    expression = """
    config = Mix.Project.config()
    deps = config[:deps] || []
    dep_names = Enum.map(deps, fn dep -> dep |> elem(0) |> Atom.to_string() end)
    IO.puts("app: \#{config[:app]}")
    IO.puts("version: \#{config[:version]}")
    IO.puts("elixir: \#{config[:elixir]}")
    IO.puts("source_paths: \#{Enum.join(config[:elixirc_paths] || ["lib"], ", ")}")
    IO.puts("dependencies: \#{Enum.join(dep_names, ", ")}")
    """

    {status, output, duration_ms} =
      run_mix(["run", "--no-start", "--no-compile", "-e", expression], ctx.cwd)

    finish_run(state, "project_info", {"elixir_project_info", %{}}, status, duration_ms, output)
  end

  def handle_tool("elixir_check", args, ctx, state) do
    case Map.get(args, "check", "all") do
      check when check in ["all", "format", "compile"] ->
        checks =
          case check do
            "all" ->
              [
                {"format", ["format", "--check-formatted"]},
                {"compile", ["compile", "--warnings-as-errors"]}
              ]

            "format" ->
              [{"format", ["format", "--check-formatted"]}]

            "compile" ->
              [{"compile", ["compile", "--warnings-as-errors"]}]
          end

        commands = Enum.map(checks, fn {_name, arguments} -> ["mix" | arguments] end)

        recorded_run(state, "check:#{check}", {"elixir_check", args}, ctx, commands, fn ->
          run_checks(checks, ctx.cwd)
        end)

      _other ->
        {{:error, "check must be one of: all, format, compile"}, state}
    end
  end

  def handle_tool("elixir_test", args, ctx, state) do
    case Map.get(args, "target") do
      nil ->
        recorded_run(state, "test:all", {"elixir_test", args}, ctx, [["mix", "test"]], fn ->
          run_mix(["test"], ctx.cwd)
        end)

      target when is_binary(target) and target != "" ->
        if String.starts_with?(target, "-") do
          {{:error, "test target cannot start with '-'"}, state}
        else
          recorded_run(
            state,
            "test:#{target}",
            {"elixir_test", args},
            ctx,
            [["mix", "test", target]],
            fn ->
              run_mix(["test", target], ctx.cwd)
            end
          )
        end

      _other ->
        {{:error, "target must be a non-empty string"}, state}
    end
  end

  def handle_tool("elixir_last_run", _args, _ctx, %{last_run: nil} = state) do
    {{:ok, "No checks or tests have run in this session."}, state}
  end

  def handle_tool("elixir_last_run", _args, _ctx, state) do
    last = state.last_run

    text =
      "run=#{state.run_count} command=#{last.command} status=#{last.status} " <>
        "exit=#{last.exit_status} duration_ms=#{last.duration_ms}"

    {{:ok, text}, state}
  end

  def handle_tool("elixir_rerun_last", _args, _ctx, %{last_run: nil} = state) do
    {{:error, "No Mix invocation to rerun in this session."}, state}
  end

  def handle_tool("elixir_rerun_last", _args, ctx, state) do
    {name, args} = state.last_run.invocation
    handle_tool(name, args, ctx, state)
  end

  def handle_tool(_name, _args, _ctx, state), do: {{:error, "unknown elixir project tool"}, state}

  defp empty_schema do
    %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
  end

  defp evidence_paths_schema do
    %{
      "type" => "array",
      "items" => %{"type" => "string"},
      "maxItems" => 4,
      "description" =>
        "Workspace-relative files to capture before the check; at most 4096 bytes per file"
    }
  end

  defp recorded_run(state, command, {name, args}, ctx, commands, run) do
    paths = Map.get(args, "evidence_paths", default_evidence_paths(args))

    with {:ok, sources} <- CheckEvidence.capture(ctx.cwd, paths) do
      {status, output, duration_ms} = run.()

      evidence =
        CheckEvidence.finish(ctx.cwd, sources, command, status, duration_ms, output)
        |> Map.put("commands", commands)

      invocation = {name, Map.put(args, "evidence_paths", paths)}

      {{kind, text}, next_state} =
        finish_run(
          state,
          command,
          invocation,
          status,
          duration_ms,
          String.replace_invalid(output)
        )

      suffix =
        case CheckEvidence.record(ctx, evidence) do
          :ok -> "\nevidence_run_id=#{evidence["id"]} (inspect with check_evidence)"
          {:error, reason} -> "\nEvidence was not retained: #{inspect(reason)}"
        end

      {{kind, text <> suffix}, next_state}
    else
      {:error, reason} ->
        {{:error, "Check not run: cannot capture selected evidence: #{inspect(reason)}"}, state}
    end
  end

  defp default_evidence_paths(%{"target" => target}) when is_binary(target) do
    path = String.replace(target, ~r/:\d+$/, "")
    if String.ends_with?(path, ".exs"), do: [path], else: []
  end

  defp default_evidence_paths(_), do: []

  defp run_checks(checks, cwd) do
    started_at = System.monotonic_time(:millisecond)

    results =
      Enum.map(checks, fn {name, arguments} ->
        {status, output, _duration_ms} = run_mix(arguments, cwd)
        {name, status, output}
      end)

    status =
      if Enum.all?(results, fn {_name, status, _output} -> status == 0 end),
        do: 0,
        else: 1

    output =
      Enum.map_join(results, "\n\n", fn {name, check_status, check_output} ->
        label = if check_status == 0, do: "ok", else: "failed (exit #{check_status})"
        body = check_output
        if body == "", do: "#{name}: #{label}", else: "#{name}: #{label}\n#{body}"
      end)

    {status, output, System.monotonic_time(:millisecond) - started_at}
  end

  defp run_mix(arguments, cwd) do
    started_at = System.monotonic_time(:millisecond)

    {output, status} =
      try do
        System.cmd("mix", arguments, cd: cwd, stderr_to_stdout: true)
      rescue
        error in ErlangError ->
          {"could not run mix: #{Exception.message(error)}", 127}
      end

    {status, output, System.monotonic_time(:millisecond) - started_at}
  end

  defp finish_run(state, command, invocation, exit_status, duration_ms, output) do
    status = if exit_status == 0, do: :ok, else: :error

    last_run = %{
      command: command,
      invocation: invocation,
      status: status,
      exit_status: exit_status,
      duration_ms: duration_ms
    }

    next_state = %{state | run_count: state.run_count + 1, last_run: last_run}
    text = "#{command} #{status} (exit #{exit_status}, #{duration_ms} ms)\n" <> compact(output)
    {{status, String.trim_trailing(text)}, next_state}
  end

  defp compact(output) do
    output = String.trim(output)

    if byte_size(output) <= @max_output_bytes do
      output
    else
      half = div(@max_output_bytes, 2)
      head = utf8_prefix(output, half)
      tail = output |> String.reverse() |> utf8_prefix(half) |> String.reverse()
      omitted = byte_size(output) - byte_size(head) - byte_size(tail)

      head <>
        "\n[... omitted #{omitted} bytes ...]\n" <>
        tail
    end
  end

  defp utf8_prefix(_text, max) when max <= 0, do: ""

  defp utf8_prefix(text, max) do
    prefix = binary_part(text, 0, max)
    if String.valid?(prefix), do: prefix, else: utf8_prefix(text, max - 1)
  end
end
