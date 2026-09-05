defmodule Elara.Chat do
  @moduledoc false

  alias Elara.Chat.Core

  @banner "elara  ·  /help  /interrupt  /reload  /resume  /quit\n\n"
  @prompt "> "

  @spec main([String.t()]) :: no_return()
  @spec main([String.t()], keyword()) :: no_return()
  def main(argv, opts \\ []) do
    seed = argv |> Enum.join(" ") |> String.trim()
    continue? = Keyword.get(opts, :continue, false)
    name = Keyword.get(opts, :name)

    case Elara.Config.resolve() do
      {:ok, provider} ->
        case Elara.start_session(provider: provider, resume: resume_opt(continue?), name: name) do
          {:ok, session} ->
            start_reader(self())
            exit({:shutdown, run(session, :stdio, seed)})

          {:error, reason} ->
            Mix.shell().error(startup_error(reason))
            exit({:shutdown, 1})
        end

      {:error, :not_logged_in} ->
        Mix.shell().error(
          "Not logged in. Run `mix elara.login`, or `mix elara.login openai` and set ELARA_PROVIDER=openai-codex, or set ELARA_API_KEY / XAI_API_KEY."
        )

        exit({:shutdown, 1})

      {:error, {:missing_env, missing}} ->
        Mix.shell().error("Missing env: #{Enum.join(missing, ", ")}")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Config error: #{Elara.Config.error_message(reason)}")
        exit({:shutdown, 1})
    end
  end

  @spec run(Elara.session_ref(), IO.device(), String.t()) :: 0 | 1
  def run(session, out, seed \\ "") do
    {:ok, session_pid} = Elara.session_pid(session)
    Process.monitor(session_pid)
    :ok = Elara.subscribe(session)
    write_out(out, @banner)
    write_out(out, Core.render_transcript(Elara.transcript(session)))

    case String.trim(seed) do
      "" ->
        write_out(out, @prompt)
        loop(session, session_pid, out, :idle, %{rewrite: false})

      prompt ->
        {phase, effects} = Core.step(:idle, {:line, prompt})

        case apply_effects(session, out, phase, effects, %{rewrite: false}) do
          {:halt, code} -> code
          {phase, opts} -> loop(session, session_pid, out, phase, opts)
        end
    end
  end

  defp loop(session, session_pid, out, phase, opts) do
    receive do
      {:stdin, :eof} ->
        dispatch(session, session_pid, out, phase, :eof, %{opts | rewrite: false})

      {:stdin, line} ->
        dispatch(session, session_pid, out, phase, {:line, line}, %{opts | rewrite: tty?(out)})

      {:elara, ^session, event} ->
        dispatch(session, session_pid, out, phase, {:event, event}, %{opts | rewrite: false})

      {:DOWN, _ref, :process, ^session_pid, reason} ->
        dispatch(session, session_pid, out, phase, {:session_down, reason}, %{
          opts
          | rewrite: false
        })

      :ask_rejected ->
        dispatch(session, session_pid, out, phase, :ask_rejected, %{opts | rewrite: false})

      {:sessions_listed, rows} ->
        dispatch(session, session_pid, out, phase, {:sessions_listed, rows}, %{
          opts
          | rewrite: false
        })

      {:resume_result, result} ->
        dispatch(session, session_pid, out, phase, {:resume_result, result}, %{
          opts
          | rewrite: false
        })

      {:user_entries_listed, kind, entries} ->
        dispatch(session, session_pid, out, phase, {:user_entries_listed, kind, entries}, %{
          opts
          | rewrite: false
        })

      {:branch_result, kind, result} ->
        dispatch(session, session_pid, out, phase, {:branch_result, kind, result}, %{
          opts
          | rewrite: false
        })

      {:action_result, kind, result} ->
        dispatch(session, session_pid, out, phase, {:action_result, kind, result}, %{
          opts
          | rewrite: false
        })

      {:reload_result, result} ->
        dispatch(session, session_pid, out, phase, {:reload_result, result}, %{
          opts
          | rewrite: false
        })

      {:why_result, result} ->
        dispatch(session, session_pid, out, phase, {:why_result, result}, %{
          opts
          | rewrite: false
        })
    end
  end

  defp dispatch(session, session_pid, out, phase, input, opts) do
    {phase, effects} = Core.step(phase, input)

    case apply_effects(session, out, phase, effects, opts) do
      {:halt, code} -> code
      {phase, opts} -> loop(session, session_pid, out, phase, opts)
    end
  end

  defp apply_effects(session, out, phase, effects, opts) do
    Enum.reduce_while(effects, {phase, opts}, fn effect, {phase, opts} ->
      case effect do
        {:print, iodata} ->
          write_print(out, iodata, opts)
          {:cont, {phase, %{opts | rewrite: false}}}

        {:ask, prompt} ->
          case Elara.ask_async(session, prompt) do
            :ok ->
              {:cont, {phase, opts}}

            {:error, :busy} ->
              send(self(), :ask_rejected)
              {:cont, {phase, opts}}
          end

        :interrupt ->
          Elara.interrupt(session)
          {:cont, {phase, opts}}

        :list_sessions ->
          send(self(), {:sessions_listed, session_rows(session)})
          {:cont, {phase, opts}}

        {:resume_session, index} ->
          send(self(), resume_result(session, index))
          {:cont, {phase, opts}}

        {:list_user_entries, kind} ->
          send(self(), {:user_entries_listed, kind, Elara.user_entries(session)})
          {:cont, {phase, opts}}

        {:select_user_entry, kind, index} ->
          send(self(), {:branch_result, kind, branch_result(session, kind, index)})
          {:cont, {phase, opts}}

        :clone_session ->
          result =
            case Elara.clone_session(session) do
              {:ok, nil, _history} -> :ok
              {:error, reason} -> {:error, reason}
            end

          send(self(), {:action_result, :clone, result})
          {:cont, {phase, opts}}

        {:name_session, name} ->
          send(self(), {:action_result, :name, Elara.name_session(session, name)})
          {:cont, {phase, opts}}

        :reload_plugins ->
          send(self(), {:reload_result, Elara.reload_plugins(session)})
          {:cont, {phase, opts}}

        {:why, selector} ->
          send(self(), {:why_result, Elara.why(session, selector)})
          {:cont, {phase, opts}}

        {:halt, code} ->
          {:halt, {:halt, code}}
      end
    end)
  end

  defp session_rows(session) do
    session
    |> Elara.cwd()
    |> Elara.list_sessions()
    |> Enum.map(&%{id: &1.id, timestamp: &1.timestamp, name: &1.name})
  end

  defp branch_result(session, kind, index) do
    case Enum.at(Elara.user_entries(session), index - 1) do
      nil -> {:error, {:invalid_index, index}}
      %{id: id} when kind == :tree -> Elara.tree(session, id)
      %{id: id} when kind == :fork -> Elara.fork(session, id)
    end
  end

  defp resume_result(session, index) do
    infos = Elara.list_sessions(Elara.cwd(session))

    case Enum.at(infos, index - 1) do
      nil ->
        {:resume_result, {:error, {:invalid_index, index}}}

      info ->
        case Elara.resume(session, info.path) do
          {:ok, history} -> {:resume_result, {:ok, history}}
          {:error, reason} -> {:resume_result, {:error, reason}}
        end
    end
  end

  defp resume_opt(true), do: :latest
  defp resume_opt(false), do: nil

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

  defp paint_line("elara  ·  /help  /interrupt  /reload  /resume  /quit" = line) do
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
  def startup_error(:locked), do: "Session is already open."
  def startup_error(:lock_unavailable), do: "Session locking requires the `flock` command."
  def startup_error(:no_home), do: "HOME is not set."
  def startup_error(reason), do: "Could not start chat: #{inspect(reason)}"
end
