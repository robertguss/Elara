defmodule Elara.Chat.Core do
  @moduledoc false

  alias Elara.CLI
  alias Elara.Message
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}

  @type phase :: :idle | {:in_turn, String.t()} | {:exiting, 0 | 1}
  @type session_row :: %{id: String.t(), timestamp: integer(), name: String.t() | nil}

  @type input ::
          {:line, String.t()}
          | :eof
          | {:event, Elara.Event.t()}
          | {:session_down, term()}
          | {:sessions_listed, [session_row()]}
          | {:resume_result, {:ok, [Message.t()]} | {:error, term()}}
          | {:user_entries_listed, :tree | :fork, [map()]}
          | {:branch_result, :tree | :fork, {:ok, String.t(), [Message.t()]} | {:error, term()}}
          | {:action_result, :clone | :name, :ok | {:error, term()}}
          | {:reload_result, {:ok, [Elara.Plugin.Info.t()]} | {:error, term()}}
          | {:why_result, {:ok, map()} | {:error, term()}}
          | :ask_rejected

  @type effect ::
          {:print, iodata()}
          | {:ask, String.t()}
          | :list_sessions
          | {:resume_session, pos_integer()}
          | {:list_user_entries, :tree | :fork}
          | {:select_user_entry, :tree | :fork, pos_integer()}
          | :clone_session
          | {:name_session, String.t()}
          | :reload_plugins
          | {:why, :latest | pos_integer()}
          | :interrupt
          | {:halt, 0 | 1}

  @commands %{
    "/quit" => :quit,
    "/exit" => :quit,
    "/q" => :quit,
    "/interrupt" => :interrupt,
    "/stop" => :interrupt,
    "/reload" => :reload,
    "/why" => :why_latest,
    "/resume" => :resume_list,
    "/tree" => :tree_list,
    "/fork" => :fork_list,
    "/clone" => :clone,
    "/help" => :help,
    "/h" => :help,
    "/?" => :help
  }

  @help """
  /help       this list
  /interrupt  cancel the current turn
  /reload     reload local plugins
  /why [N]    explain the latest event, or event N
  /resume     list saved sessions
  /resume N   resume saved session N
  /tree       list user turns; /tree N branches in this session
  /fork       list user turns; /fork N branches into a new session
  /clone      copy the current path into a new session
  /name TEXT  name the current session
  /quit       exit
  """

  @refuse "in a turn. /interrupt to cancel.\n"
  @rejected "busy. wait for the turn or /interrupt.\n"
  @session_down "session ended\n"
  @prompt "> "
  @idle_prompt "\n> "

  @spec step(phase(), input()) :: {phase(), [effect()]}
  def step(phase, input)

  def step(:idle, {:line, line}), do: idle_line(parse(line))
  def step(:idle, :eof), do: {:idle, [{:halt, 0}]}
  def step(:idle, :ask_rejected), do: {:idle, print([@rejected, @prompt])}
  def step(:idle, {:session_down, _}), do: halt_down()
  def step(:idle, {:sessions_listed, infos}), do: {:idle, print([session_list(infos), @prompt])}

  def step(:idle, {:user_entries_listed, kind, entries}) do
    {:idle, print([user_entry_list(kind, entries), @prompt])}
  end

  def step(:idle, {:branch_result, kind, {:ok, prompt, _history}}) do
    label = if kind == :tree, do: "branched in current session\n", else: "forked session\n"
    {{:in_turn, prompt}, print(label) ++ [{:print, user_block(prompt)}, {:ask, prompt}]}
  end

  def step(:idle, {:branch_result, _kind, {:error, reason}}) do
    {:idle, print([action_error(reason), @prompt])}
  end

  def step(:idle, {:action_result, kind, :ok}) do
    text = if kind == :clone, do: "cloned session\n", else: "session named\n"
    {:idle, print([text, @prompt])}
  end

  def step(:idle, {:action_result, _kind, {:error, reason}}) do
    {:idle, print([action_error(reason), @prompt])}
  end

  def step(:idle, {:reload_result, result}) do
    {:idle, print([reload_result(result), @prompt])}
  end

  def step(:idle, {:why_result, result}) do
    {:idle, print([why_result(result), @prompt])}
  end

  def step(:idle, {:resume_result, {:ok, history}}) do
    {:idle, print([render_transcript(history), @prompt])}
  end

  def step(:idle, {:resume_result, {:error, reason}}) do
    {:idle, print([resume_error(reason), @prompt])}
  end

  def step(:idle, {:event, _}), do: {:idle, []}

  def step({:in_turn, prompt} = phase, {:line, line}) do
    in_turn_line(phase, prompt, parse(line))
  end

  def step({:in_turn, _}, :eof), do: {{:exiting, 0}, [:interrupt]}
  def step({:in_turn, _}, :ask_rejected), do: {:idle, print([@rejected, @prompt])}
  def step({:in_turn, _}, {:session_down, _}), do: halt_down()
  def step({:in_turn, _} = phase, {:sessions_listed, _}), do: {phase, []}
  def step({:in_turn, _} = phase, {:resume_result, _}), do: {phase, []}
  def step({:in_turn, _} = phase, {:user_entries_listed, _, _}), do: {phase, []}
  def step({:in_turn, _} = phase, {:branch_result, _, _}), do: {phase, []}
  def step({:in_turn, _} = phase, {:action_result, _, _}), do: {phase, []}
  def step({:in_turn, _} = phase, {:reload_result, _}), do: {phase, []}
  def step({:in_turn, _} = phase, {:why_result, _}), do: {phase, []}

  def step({:in_turn, prompt}, {:event, event}) do
    in_turn_event(prompt, event)
  end

  def step({:exiting, code} = phase, {:line, line}) do
    case parse(line) do
      :quit -> {phase, [{:halt, code}]}
      _ -> {phase, []}
    end
  end

  def step({:exiting, code} = phase, :eof), do: {phase, [{:halt, code}]}
  def step({:exiting, _code} = phase, :ask_rejected), do: {phase, []}
  def step({:exiting, _}, {:session_down, _}), do: halt_down()
  def step({:exiting, _} = phase, {:sessions_listed, _}), do: {phase, []}
  def step({:exiting, _} = phase, {:resume_result, _}), do: {phase, []}
  def step({:exiting, _} = phase, {:user_entries_listed, _, _}), do: {phase, []}
  def step({:exiting, _} = phase, {:branch_result, _, _}), do: {phase, []}
  def step({:exiting, _} = phase, {:action_result, _, _}), do: {phase, []}
  def step({:exiting, _} = phase, {:reload_result, _}), do: {phase, []}
  def step({:exiting, _} = phase, {:why_result, _}), do: {phase, []}

  def step({:exiting, code} = phase, {:event, {:turn_ended, outcome} = event}) do
    {phase, end_prints(outcome, event) ++ [{:halt, code}]}
  end

  def step({:exiting, _code} = phase, {:event, event}) do
    {phase, event_prints(event)}
  end

  defp idle_line(:empty), do: {:idle, print(@prompt)}
  defp idle_line(:quit), do: {:idle, [{:halt, 0}]}
  defp idle_line(:interrupt), do: {:idle, print(@prompt)}
  defp idle_line(:help), do: {:idle, print([@help, @prompt])}
  defp idle_line(:reload), do: {:idle, [:reload_plugins]}
  defp idle_line(:why_latest), do: {:idle, [{:why, :latest}]}
  defp idle_line({:why, sequence}), do: {:idle, [{:why, sequence}]}
  defp idle_line(:invalid_why), do: {:idle, print(["usage: /why or /why N\n", @prompt])}
  defp idle_line(:resume_list), do: {:idle, [:list_sessions]}
  defp idle_line({:resume, index}), do: {:idle, [{:resume_session, index}]}
  defp idle_line(:invalid_resume), do: {:idle, print(["usage: /resume or /resume N\n", @prompt])}
  defp idle_line(:tree_list), do: {:idle, [{:list_user_entries, :tree}]}
  defp idle_line(:fork_list), do: {:idle, [{:list_user_entries, :fork}]}
  defp idle_line({:tree, index}), do: {:idle, [{:select_user_entry, :tree, index}]}
  defp idle_line({:fork, index}), do: {:idle, [{:select_user_entry, :fork, index}]}
  defp idle_line(:clone), do: {:idle, [:clone_session]}
  defp idle_line({:name, name}), do: {:idle, [{:name_session, name}]}
  defp idle_line(:invalid_tree), do: {:idle, print(["usage: /tree or /tree N\n", @prompt])}
  defp idle_line(:invalid_fork), do: {:idle, print(["usage: /fork or /fork N\n", @prompt])}
  defp idle_line(:invalid_name), do: {:idle, print(["usage: /name TEXT\n", @prompt])}

  defp idle_line({:unknown, cmd}),
    do: {:idle, print(["unknown command ", cmd, ". /help\n", @prompt])}

  defp idle_line({:prompt, text}) do
    {{:in_turn, text}, [{:print, user_block(text)}, {:ask, text}]}
  end

  defp in_turn_line(phase, _prompt, :empty), do: {phase, []}
  defp in_turn_line(_phase, _prompt, :quit), do: {{:exiting, 0}, [:interrupt]}
  defp in_turn_line(phase, _prompt, :interrupt), do: {phase, [:interrupt]}
  defp in_turn_line(phase, _prompt, :help), do: {phase, print(@help)}
  defp in_turn_line(phase, _prompt, :resume_list), do: {phase, print(@refuse)}
  defp in_turn_line(phase, _prompt, {:resume, _}), do: {phase, print(@refuse)}
  defp in_turn_line(phase, _prompt, :invalid_resume), do: {phase, print(@refuse)}

  defp in_turn_line(phase, _prompt, command)
       when command in [
              :tree_list,
              :fork_list,
              :clone,
              :reload,
              :why_latest,
              :invalid_why,
              :invalid_tree,
              :invalid_fork,
              :invalid_name
            ],
       do: {phase, print(@refuse)}

  defp in_turn_line(phase, _prompt, {command, _})
       when command in [:tree, :fork, :name, :why],
       do: {phase, print(@refuse)}

  defp in_turn_line(phase, _prompt, {:unknown, _}), do: {phase, print(@refuse)}
  defp in_turn_line(phase, _prompt, {:prompt, _}), do: {phase, print(@refuse)}

  defp in_turn_event(_prompt, {:turn_ended, {:completed, _}}) do
    {:idle, print(@idle_prompt)}
  end

  defp in_turn_event(_prompt, {:turn_ended, outcome} = event) do
    {:idle, end_prints(outcome, event) ++ print(@idle_prompt)}
  end

  defp in_turn_event(prompt, event) do
    {{:in_turn, prompt}, event_prints(event)}
  end

  defp end_prints({:completed, _}, _event), do: []
  defp end_prints(:interrupted, _event), do: print("    interrupted\n")
  defp end_prints(:turn_limit, _event), do: print("    turn limit\n")

  defp end_prints({:provider_error, err}, _event) do
    print(["    error · ", err.message, "\n"])
  end

  defp event_prints({:turn_started, _}), do: []
  defp event_prints({:message_appended, %User{}}), do: []

  defp event_prints({:tool_started, %ToolCall{name: name, args: args}}) do
    print(tool_started_line(name, args))
  end

  defp event_prints({:message_appended, %ToolResult{outcome: outcome}}) do
    print(tool_result_line(outcome))
  end

  defp event_prints(event) do
    print(CLI.render(event))
  end

  defp user_block(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&["  ", &1, "\n"])

    ["  you\n", lines, "\n"]
  end

  defp tool_started_line(name, args) do
    case tool_detail(args) do
      nil -> ["    ", name, "\n"]
      detail -> ["    ", name, " · ", detail, "\n"]
    end
  end

  defp tool_result_line({:ok, text}) do
    lines = text |> String.split("\n") |> length()
    ["    ok · ", Integer.to_string(lines), " lines\n\n"]
  end

  defp tool_result_line({:error, text}) do
    first = text |> String.split("\n") |> hd()
    ["    error · ", first, "\n\n"]
  end

  defp tool_result_line({:indeterminate, text}) do
    first = text |> String.split("\n") |> hd()
    ["    indeterminate · ", first, "\n\n"]
  end

  defp tool_detail({:ok, map}) when map_size(map) == 0, do: nil

  defp tool_detail({:ok, map}) do
    value =
      cond do
        Map.has_key?(map, "command") -> Map.fetch!(map, "command")
        Map.has_key?(map, "path") -> Map.fetch!(map, "path")
        true -> map |> Map.values() |> List.first()
      end

    value |> to_string() |> String.replace(~r/\s+/, " ") |> String.slice(0, 60)
  end

  defp tool_detail({:malformed, raw}), do: String.slice(raw, 0, 40)

  @doc false
  @spec render_transcript([Message.t()]) :: iodata()
  def render_transcript(history) when is_list(history) do
    Enum.map(history, fn
      %User{text: text} -> user_block(text)
      %Assistant{} = assistant -> CLI.render({:message_appended, assistant})
      %ToolResult{outcome: outcome} -> tool_result_line(outcome)
    end)
  end

  defp parse(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :empty

      Map.has_key?(@commands, trimmed) ->
        Map.fetch!(@commands, trimmed)

      String.starts_with?(trimmed, "//") ->
        {:prompt, String.replace_prefix(trimmed, "/", "")}

      Regex.match?(~r/^\/resume\s/, trimmed) ->
        parse_resume(trimmed)

      Regex.match?(~r/^\/tree(?:\s|$)/, trimmed) ->
        parse_index_command(trimmed, "/tree", :tree, :invalid_tree)

      Regex.match?(~r/^\/fork(?:\s|$)/, trimmed) ->
        parse_index_command(trimmed, "/fork", :fork, :invalid_fork)

      Regex.match?(~r/^\/name(?:\s|$)/, trimmed) ->
        parse_name(trimmed)

      Regex.match?(~r/^\/why\s/, trimmed) ->
        parse_index_command(trimmed, "/why", :why, :invalid_why)

      String.starts_with?(trimmed, "/") ->
        {:unknown, trimmed}

      true ->
        {:prompt, trimmed}
    end
  end

  defp parse_resume(trimmed) do
    case String.split(trimmed, ~r/\s+/, trim: true) do
      ["/resume", raw_index] ->
        case Integer.parse(raw_index) do
          {index, ""} when index > 0 -> {:resume, index}
          _ -> :invalid_resume
        end

      _ ->
        :invalid_resume
    end
  end

  defp parse_index_command(trimmed, command, tag, invalid) do
    case String.split(trimmed, ~r/\s+/, trim: true) do
      [^command, raw_index] ->
        case Integer.parse(raw_index) do
          {index, ""} when index > 0 -> {tag, index}
          _ -> invalid
        end

      _ ->
        invalid
    end
  end

  defp parse_name(trimmed) do
    case String.split(trimmed, ~r/\s+/, parts: 2, trim: true) do
      ["/name", name] when name != "" -> {:name, name}
      _ -> :invalid_name
    end
  end

  defp reload_result({:ok, []}), do: "no plugins loaded\n"

  defp reload_result({:ok, infos}) do
    Enum.map(infos, fn info ->
      "reloaded #{info.id} #{info.version} (generation #{info.generation})\n"
    end)
  end

  defp reload_result({:error, :busy}), do: "plugins are busy\n"

  defp reload_result({:error, {:plugin_reload_failed, _path, :busy}}) do
    "plugins are busy\n"
  end

  defp reload_result({:error, {:plugin_reload_failed, path, reason}}) do
    "reload failed for #{path}: #{inspect(reason)}\n"
  end

  defp reload_result({:error, reason}), do: "reload failed: #{inspect(reason)}\n"

  defp why_result({:ok, explanation}) do
    id = explanation.transition_id

    chain =
      Enum.map_join(explanation.chain, " -> ", &Integer.to_string(&1.transition_id.sequence))

    [
      "transition ",
      id.recording_id,
      ":",
      Integer.to_string(id.sequence),
      " effect ",
      to_string(explanation.effect_index || "-"),
      "\nfact: ",
      inspect(explanation.fact),
      "\ncausal chain: ",
      chain,
      "\n"
    ]
  end

  defp why_result({:error, :not_found}), do: "no recorded transition for that event\n"
  defp why_result({:error, reason}), do: "why failed: #{inspect(reason)}\n"

  defp session_list([]), do: "no saved sessions for this directory\n"

  defp session_list(infos) do
    rows =
      infos
      |> Enum.with_index(1)
      |> Enum.map(fn {%{id: id, timestamp: timestamp} = info, index} ->
        name = Map.get(info, :name)

        [
          Integer.to_string(index),
          "  ",
          timestamp |> DateTime.from_unix!() |> DateTime.to_iso8601(),
          "  ",
          id,
          if(name, do: ["  ", name], else: []),
          "\n"
        ]
      end)

    ["saved sessions\n", rows]
  end

  defp user_entry_list(_kind, []), do: "no user turns in this session\n"

  defp user_entry_list(kind, entries) do
    command = if kind == :tree, do: "/tree", else: "/fork"

    rows =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {%{text: text}, index} ->
        summary = text |> String.replace(~r/\s+/, " ") |> String.slice(0, 80)
        [Integer.to_string(index), "  ", summary, "\n"]
      end)

    ["user turns (choose with ", command, " N)\n", rows]
  end

  defp action_error({:invalid_index, index}),
    do: ["no user turn at index ", Integer.to_string(index), "\n"]

  defp action_error(reason), do: ["session command failed: ", inspect(reason), "\n"]

  defp resume_error({:invalid_index, index}) do
    ["no saved session at index ", Integer.to_string(index), "\n"]
  end

  defp resume_error(:enoent), do: "session file no longer exists\n"
  defp resume_error(reason), do: ["could not resume session: ", inspect(reason), "\n"]

  defp print(iodata) do
    case IO.iodata_to_binary(iodata) do
      "" -> []
      binary -> [{:print, binary}]
    end
  end

  defp halt_down, do: {:idle, [{:print, @session_down}, {:halt, 1}]}
end
