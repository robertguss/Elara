defmodule Harness.Chat.Core do
  @moduledoc false

  alias Harness.CLI
  alias Harness.Message
  alias Harness.Message.{Assistant, ToolCall, ToolResult, User}

  @type phase :: :idle | {:in_turn, String.t()} | {:exiting, 0 | 1}
  @type session_row :: %{id: String.t(), timestamp: integer()}

  @type input ::
          {:line, String.t()}
          | :eof
          | {:event, Harness.Event.t()}
          | {:session_down, term()}
          | {:sessions_listed, [session_row()]}
          | {:resume_result, {:ok, [Message.t()]} | {:error, term()}}
          | :ask_rejected

  @type effect ::
          {:print, iodata()}
          | {:ask, String.t()}
          | :list_sessions
          | {:resume_session, pos_integer()}
          | :interrupt
          | {:halt, 0 | 1}

  @commands %{
    "/quit" => :quit,
    "/exit" => :quit,
    "/q" => :quit,
    "/interrupt" => :interrupt,
    "/stop" => :interrupt,
    "/resume" => :resume_list,
    "/help" => :help,
    "/h" => :help,
    "/?" => :help
  }

  @help """
  /help       this list
  /interrupt  cancel the current turn
  /resume     list saved sessions
  /resume N   resume saved session N
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
  defp idle_line(:resume_list), do: {:idle, [:list_sessions]}
  defp idle_line({:resume, index}), do: {:idle, [{:resume_session, index}]}
  defp idle_line(:invalid_resume), do: {:idle, print(["usage: /resume or /resume N\n", @prompt])}

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

  defp session_list([]), do: "no saved sessions for this directory\n"

  defp session_list(infos) do
    rows =
      infos
      |> Enum.with_index(1)
      |> Enum.map(fn {%{id: id, timestamp: timestamp}, index} ->
        [
          Integer.to_string(index),
          "  ",
          timestamp |> DateTime.from_unix!() |> DateTime.to_iso8601(),
          "  ",
          id,
          "\n"
        ]
      end)

    ["saved sessions\n", rows]
  end

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
