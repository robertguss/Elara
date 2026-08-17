defmodule Harness.Chat.Core do
  @moduledoc false

  alias Harness.CLI
  alias Harness.Message.{ToolCall, ToolResult, User}

  @type phase :: :idle | {:in_turn, String.t()} | {:exiting, 0 | 1}

  @type input ::
          {:line, String.t()}
          | :eof
          | {:event, Harness.Event.t()}
          | {:session_down, term()}
          | :ask_rejected

  @type effect ::
          {:print, iodata()}
          | {:ask, String.t()}
          | :interrupt
          | {:halt, 0 | 1}

  @commands %{
    "/quit" => :quit,
    "/exit" => :quit,
    "/q" => :quit,
    "/interrupt" => :interrupt,
    "/stop" => :interrupt,
    "/help" => :help,
    "/h" => :help,
    "/?" => :help
  }

  @help """
  /help       this list
  /interrupt  cancel the current turn
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
  def step(:idle, {:event, _}), do: {:idle, []}

  def step({:in_turn, prompt} = phase, {:line, line}) do
    in_turn_line(phase, prompt, parse(line))
  end

  def step({:in_turn, _}, :eof), do: {{:exiting, 0}, [:interrupt]}
  def step({:in_turn, _}, :ask_rejected), do: {:idle, print([@rejected, @prompt])}
  def step({:in_turn, _}, {:session_down, _}), do: halt_down()

  def step({:in_turn, prompt}, {:event, event}) do
    in_turn_event(prompt, event)
  end

  def step({:exiting, _code} = phase, {:line, _}), do: {phase, []}
  def step({:exiting, _code} = phase, :eof), do: {phase, []}
  def step({:exiting, _code} = phase, :ask_rejected), do: {phase, []}
  def step({:exiting, _}, {:session_down, _}), do: halt_down()

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

  defp idle_line({:unknown, cmd}),
    do: {:idle, print(["unknown command ", cmd, ". /help\n", @prompt])}

  defp idle_line({:prompt, text}) do
    {{:in_turn, text}, [{:print, user_block(text)}, {:ask, text}]}
  end

  defp in_turn_line(phase, _prompt, :empty), do: {phase, []}
  defp in_turn_line(_phase, _prompt, :quit), do: {{:exiting, 0}, [:interrupt]}
  defp in_turn_line(phase, _prompt, :interrupt), do: {phase, [:interrupt]}
  defp in_turn_line(phase, _prompt, :help), do: {phase, print(@help)}
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

  defp parse(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :empty

      Map.has_key?(@commands, trimmed) ->
        Map.fetch!(@commands, trimmed)

      String.starts_with?(trimmed, "//") ->
        {:prompt, String.replace_prefix(trimmed, "/", "")}

      String.starts_with?(trimmed, "/") ->
        {:unknown, trimmed}

      true ->
        {:prompt, trimmed}
    end
  end

  defp print(iodata) do
    case IO.iodata_to_binary(iodata) do
      "" -> []
      binary -> [{:print, binary}]
    end
  end

  defp halt_down, do: {:idle, [{:print, @session_down}, {:halt, 1}]}
end
