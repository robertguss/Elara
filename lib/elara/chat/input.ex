defmodule Elara.Chat.Input do
  @moduledoc false

  def new, do: %{pasting: false, pasted: false, text: ""}

  # IO.gets splits pasted newlines but preserves terminal bracketed-paste markers.
  # Only a newline outside those markers submits the draft; no timing heuristic.
  def feed(state, line) do
    Regex.split(~r/(\e\[200~|\e\[201~|\r?\n)/, line, include_captures: true, trim: true)
    |> Enum.reduce({state, []}, fn
      "\e[200~", {state, inputs} ->
        {%{state | pasting: true, pasted: true}, inputs}

      "\e[201~", {state, inputs} ->
        {%{state | pasting: false}, inputs}

      newline, {%{pasting: true} = state, inputs} when newline in ["\n", "\r\n"] ->
        {%{state | text: state.text <> "\n"}, inputs}

      newline, {state, inputs} when newline in ["\n", "\r\n"] ->
        {new(), [input(state) | inputs]}

      text, {state, inputs} ->
        {%{state | text: state.text <> text}, inputs}
    end)
    |> then(fn {state, inputs} -> {state, Enum.reverse(inputs)} end)
  end

  def finish(%{pasted: false, text: text} = state) when text != "",
    do: [input(state), :eof]

  # An unfinished paste is never submitted by EOF, even after its closing marker.
  def finish(_state), do: [:eof]

  def read(parent, device \\ :stdio, state \\ new()) do
    case IO.gets(device, "") do
      line when is_binary(line) ->
        {state, inputs} = feed(state, line)
        Enum.each(inputs, &send(parent, {:stdin, &1}))
        read(parent, device, state)

      _eof_or_error ->
        Enum.each(finish(state), &send(parent, {:stdin, &1}))
    end
  end

  defp input(%{pasted: true, text: text}), do: {:paste, text}
  defp input(%{text: text}), do: text <> "\n"
end
