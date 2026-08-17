defmodule Harness.Chat do
  @moduledoc false

  alias Harness.Chat.Core

  @banner "harness  ·  /help  /interrupt  /resume  /quit\n\n"
  @prompt "> "

  @spec main([String.t()]) :: no_return()
  @spec main([String.t()], keyword()) :: no_return()
  def main(argv, opts \\ []) do
    seed = argv |> Enum.join(" ") |> String.trim()
    continue? = Keyword.get(opts, :continue, false)

    case Harness.Config.resolve() do
      {:ok, provider} ->
        case Harness.start_session(provider: provider, continue: continue?) do
          {:ok, session} ->
            start_reader(self())
            exit({:shutdown, run(session, :stdio, seed)})

          {:error, reason} ->
            Mix.shell().error(startup_error(reason))
            exit({:shutdown, 1})
        end

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
    write_out(out, Core.render_transcript(Harness.transcript(session)))

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

        :list_sessions ->
          continue_with(
            session,
            out,
            phase,
            {:sessions_listed, Harness.sessions(session)},
            opts
          )

        {:resume_session, index} ->
          continue_with(session, out, phase, resume_input(session, index), opts)

        {:halt, code} ->
          {:halt, {:halt, code}}
      end
    end)
  end

  defp continue_with(session, out, phase, input, opts) do
    {next_phase, effects} = Core.step(phase, input)

    case apply_effects(session, out, next_phase, effects, opts) do
      {:halt, code} -> {:halt, {:halt, code}}
      state -> {:cont, state}
    end
  end

  defp resume_input(session, index) do
    case Enum.at(Harness.sessions(session), index - 1) do
      nil ->
        {:resume_result, {:error, {:invalid_index, index}}}

      info ->
        case Harness.resume(session, info.path) do
          :ok -> {:resume_result, {:ok, Harness.transcript(session)}}
          {:error, reason} -> {:resume_result, {:error, reason}}
        end
    end
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

  defp paint_line("harness  ·  /help  /interrupt  /resume  /quit" = line) do
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

  @doc false
  @spec startup_error(term()) :: String.t()
  def startup_error(:no_session), do: "No saved session for this directory."
  def startup_error(reason), do: "Could not start chat: #{inspect(reason)}"
end
