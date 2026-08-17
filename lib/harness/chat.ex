defmodule Harness.Chat do
  @moduledoc false

  alias Harness.Chat.Core

  @banner "harness  ·  /help  /interrupt  /quit\n\n"
  @prompt "> "

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    seed = argv |> Enum.join(" ") |> String.trim()

    case Harness.Config.resolve() do
      {:ok, provider} ->
        {:ok, session} = Harness.start_session(provider: provider)
        start_reader(self())
        exit({:shutdown, run(session, :stdio, seed)})

      {:error, :not_logged_in} ->
        Mix.shell().error(
          "Not logged in. Run `mix harness.login` or set HARNESS_API_KEY / XAI_API_KEY."
        )

        exit({:shutdown, 1})

      {:error, {:missing_env, missing}} ->
        Mix.shell().error("Missing env: #{Enum.join(missing, ", ")}")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Config error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  @spec run(pid(), IO.device(), String.t()) :: 0 | 1
  def run(session, out, seed \\ "") do
    Process.monitor(session)
    :ok = Harness.subscribe(session)
    write_out(out, @banner)

    case String.trim(seed) do
      "" ->
        write_out(out, @prompt)
        loop(session, out, :idle, %{rewrite: false})

      prompt ->
        {phase, effects} = Core.step(:idle, {:line, prompt})

        case apply_effects(session, out, phase, effects, %{rewrite: false}) do
          {:halt, code} -> code
          {phase, opts} -> loop(session, out, phase, opts)
        end
    end
  end

  defp loop(session, out, phase, opts) do
    receive do
      {:stdin, :eof} ->
        dispatch(session, out, phase, :eof, %{opts | rewrite: false})

      {:stdin, line} ->
        dispatch(session, out, phase, {:line, line}, %{opts | rewrite: tty?(out)})

      {:harness, ^session, event} ->
        dispatch(session, out, phase, {:event, event}, %{opts | rewrite: false})

      {:DOWN, _ref, :process, ^session, reason} ->
        dispatch(session, out, phase, {:session_down, reason}, %{opts | rewrite: false})

      :ask_rejected ->
        dispatch(session, out, phase, :ask_rejected, %{opts | rewrite: false})
    end
  end

  defp dispatch(session, out, phase, input, opts) do
    {phase, effects} = Core.step(phase, input)

    case apply_effects(session, out, phase, effects, opts) do
      {:halt, code} -> code
      {phase, opts} -> loop(session, out, phase, opts)
    end
  end

  defp apply_effects(session, out, phase, effects, opts) do
    Enum.reduce_while(effects, {phase, opts}, fn effect, {phase, opts} ->
      case effect do
        {:print, iodata} ->
          write_print(out, iodata, opts)
          {:cont, {phase, %{opts | rewrite: false}}}

        {:ask, prompt} ->
          case Harness.ask_async(session, prompt) do
            :ok ->
              {:cont, {phase, opts}}

            {:error, :busy} ->
              send(self(), :ask_rejected)
              {:cont, {phase, opts}}
          end

        :interrupt ->
          Harness.interrupt(session)
          {:cont, {phase, opts}}

        {:halt, code} ->
          {:halt, {:halt, code}}
      end
    end)
  end

  defp start_reader(parent) do
    spawn_link(fn -> reader_loop(parent) end)
  end

  defp reader_loop(parent) do
    case IO.gets("") do
      :eof ->
        send(parent, {:stdin, :eof})

      {:error, _} ->
        send(parent, {:stdin, :eof})

      line when is_binary(line) ->
        send(parent, {:stdin, line})
        reader_loop(parent)
    end
  end

  defp write_print(out, iodata, opts) do
    binary = IO.iodata_to_binary(iodata)

    if user_block?(binary) do
      if opts.rewrite and tty?(out) do
        # Tty already echoed `> line`. Replace that line with the user block.
        IO.write(out, [IO.ANSI.cursor_up(), IO.ANSI.clear_line()])
      else
        IO.write(out, "\n")
      end
    end

    write_out(out, binary)
  end

  defp user_block?(binary), do: String.starts_with?(binary, "  you\n")

  defp write_out(out, iodata) do
    IO.write(out, colorize(out, iodata))
  end

  defp colorize(out, iodata) do
    if paint?(out) do
      iodata |> IO.iodata_to_binary() |> paint_chunk()
    else
      iodata
    end
  end

  defp paint?(out) do
    IO.ANSI.enabled?() and out in [:stdio, :standard_io, :stderr, :standard_error]
  end

  defp tty?(out) do
    out in [:stdio, :standard_io] and terminal?(out)
  end

  defp terminal?(out) do
    case :io.getopts(out) do
      opts when is_list(opts) -> Keyword.get(opts, :terminal, false)
      _ -> false
    end
  end

  defp paint_chunk(text) do
    text
    |> String.split("\n")
    |> Enum.map(&paint_line/1)
    |> Enum.intersperse("\n")
  end

  defp paint_line(""), do: ""
  defp paint_line(@prompt), do: [IO.ANSI.cyan(), @prompt, IO.ANSI.reset()]

  defp paint_line("harness  ·  /help  /interrupt  /quit" = line) do
    faint(line)
  end

  defp paint_line("  you"), do: faint("  you")

  defp paint_line(line) do
    if String.starts_with?(line, "    ") do
      faint(line)
    else
      line
    end
  end

  defp faint(text), do: [IO.ANSI.faint(), text, IO.ANSI.reset()]
end
