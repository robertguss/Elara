defmodule Elara.CLI do
  @moduledoc false

  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}

  @spec main([String.t()], keyword()) :: :ok | no_return()
  def main(argv, options \\ []) do
    {prompt, opts} =
      case parse_args(argv) do
        {:ok, prompt, opts} ->
          {prompt, opts}

        {:error, message} ->
          Mix.shell().error(message)
          exit({:shutdown, 1})
      end

    provider =
      if Keyword.has_key?(options, :provider),
        do: Keyword.fetch(options, :provider),
        else: Elara.Config.resolve()

    case provider do
      {:ok, provider} ->
        run_ask(prompt, provider, opts)

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

  @doc false
  def parse_args(argv) do
    case OptionParser.parse(argv, strict: [cwd: :string]) do
      {opts, remaining, []} ->
        prompt = remaining |> Enum.join(" ") |> String.trim()

        with {:ok, opts} <- workspace_options(opts) do
          if prompt == "" do
            {:error, "usage: mix elara.ask [--cwd DIR] [--] \"prompt\""}
          else
            {:ok, prompt, opts}
          end
        end

      {_opts, _remaining, [{flag, _value} | _]} ->
        {:error, "unknown or missing option value: #{flag}"}
    end
  end

  @doc false
  def workspace_options(opts) do
    case Keyword.fetch(opts, :cwd) do
      :error ->
        {:ok, opts}

      {:ok, cwd} ->
        if cwd != "" and File.dir?(Path.expand(cwd)) do
          {:ok, Keyword.put(opts, :cwd, Path.expand(cwd))}
        else
          {:error, "--cwd must name an existing directory: #{inspect(cwd)}"}
        end
    end
  end

  @doc "Pure. One event to iodata."
  @spec render(Elara.Event.t()) :: iodata()
  def render(:provider_view_changed), do: []

  def render({:turn_started, prompt}), do: ["[turn] ", prompt, "\n"]

  def render({:tool_started, %ToolCall{name: name, args: args}}) do
    ["  -> ", name, ": ", arg_summary(args), "\n"]
  end

  def render({:command_blocked, _call, reason}), do: ["[blocked] ", reason, "\n"]

  def render({:approval_required, pending}),
    do: [
      "[approval required] ",
      pending["reason"],
      "\nUse /approve from a controlling TUI for request ",
      pending["id"],
      "\n"
    ]

  def render({:approval_granted, _pending}), do: ["[approved] exact request\n"]

  def render({:message_appended, %ToolResult{outcome: {:ok, text}}}) do
    lines = text |> String.split("\n") |> length()
    ["  <- ok (", Integer.to_string(lines), " lines)\n"]
  end

  def render({:message_appended, %ToolResult{outcome: {:error, text}}}) do
    first = text |> String.split("\n") |> hd()
    ["  <- error: ", first, "\n"]
  end

  def render({:message_appended, %ToolResult{outcome: {:indeterminate, text}}}) do
    first = text |> String.split("\n") |> hd()
    ["  <- indeterminate: ", first, "\n"]
  end

  def render({:message_appended, %Assistant{text: text}}) when is_binary(text) and text != "" do
    [text, "\n"]
  end

  def render({:message_appended, %Assistant{}, :streamed}), do: ["\n"]
  def render({:content_delta, _message_id, text}), do: [text]
  def render({:message_appended, %Assistant{}}), do: []
  def render({:message_appended, %User{}}), do: []

  def render({:message_appended, %Elara.Message.System{text: text}}),
    do: ["[system] ", text, "\n"]

  def render({:provider_retry, retry}) do
    [
      "[retry] attempt ",
      Integer.to_string(retry.attempt),
      " of ",
      Integer.to_string(retry.max_attempts),
      " in ",
      seconds(retry.delay_ms),
      "s · ",
      retry.error.message,
      "\n"
    ]
  end

  def render({:turn_ended, {:completed, _text}}), do: ["[done]\n"]
  def render({:turn_ended, :turn_limit}), do: ["[done] turn limit\n"]
  def render({:turn_ended, :interrupted}), do: ["[done] interrupted\n"]

  def render({:turn_ended, {:provider_error, err}}) do
    ["[done] provider error: ", err.message, "\n"]
  end

  def render({:turn_ended, outcome, :streamed}), do: ["\n", render({:turn_ended, outcome})]

  defp seconds(milliseconds), do: :erlang.float_to_binary(milliseconds / 1000, decimals: 1)

  defp run_ask(prompt, provider, opts) do
    {:ok, session} =
      Elara.start_session(opts ++ [provider: provider, persist: false, approval_wait: false])

    {:ok, session_pid} = Elara.session_pid(session)
    ref = Process.monitor(session_pid)
    :ok = Elara.subscribe(session)
    :ok = Elara.ask_async(session, prompt)
    loop(session, session_pid, ref, false)
  end

  defp loop(session, session_pid, ref, approval_required) do
    receive do
      {:elara, ^session, event} ->
        IO.write(render(event))

        case event do
          {:turn_ended, {:completed, _}} ->
            if approval_required, do: exit({:shutdown, 1}), else: :ok

          {:turn_ended, _} ->
            exit({:shutdown, 1})

          {:turn_ended, _outcome, :streamed} ->
            exit({:shutdown, 1})

          {:message_appended, %ToolResult{outcome: outcome}} ->
            required = match?({:error, "approval required:" <> _}, outcome)
            loop(session, session_pid, ref, required)

          _ ->
            loop(session, session_pid, ref, approval_required)
        end

      {:DOWN, ^ref, :process, ^session_pid, _reason} ->
        Mix.shell().error("session ended")
        exit({:shutdown, 1})
    after
      600_000 ->
        Mix.shell().error("timed out waiting for turn")
        exit({:shutdown, 1})
    end
  end

  defp arg_summary({:ok, map}) when map_size(map) == 0, do: "{}"

  defp arg_summary({:ok, map}) do
    map
    |> Enum.map(fn {k, v} ->
      val = v |> to_string() |> String.replace(~r/\s+/, " ") |> String.slice(0, 60)
      "#{k}=#{val}"
    end)
    |> Enum.join(" ")
  end

  defp arg_summary({:malformed, raw}), do: "malformed #{String.slice(raw, 0, 40)}"
end
