defmodule Elara.CLI do
  @moduledoc false

  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}

  @spec main([String.t()]) :: :ok | no_return()
  def main(argv) do
    prompt = argv |> Enum.join(" ") |> String.trim()

    if prompt == "" do
      Mix.shell().error("usage: mix elara.ask \"prompt\"")
      exit({:shutdown, 1})
    end

    case Elara.Config.resolve() do
      {:ok, provider} ->
        run_ask(prompt, provider)

      {:error, :not_logged_in} ->
        Mix.shell().error(
          "Not logged in. Run `mix elara.login` or set ELARA_API_KEY / XAI_API_KEY."
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

  @doc "Pure. One event to iodata."
  @spec render(Elara.Event.t()) :: iodata()
  def render({:turn_started, prompt}), do: ["[turn] ", prompt, "\n"]

  def render({:tool_started, %ToolCall{name: name, args: args}}) do
    ["  -> ", name, ": ", arg_summary(args), "\n"]
  end

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

  def render({:turn_ended, {:completed, _text}}), do: ["[done]\n"]
  def render({:turn_ended, :turn_limit}), do: ["[done] turn limit\n"]
  def render({:turn_ended, :interrupted}), do: ["[done] interrupted\n"]

  def render({:turn_ended, {:provider_error, err}}) do
    ["[done] provider error: ", err.message, "\n"]
  end

  def render({:turn_ended, outcome, :streamed}), do: ["\n", render({:turn_ended, outcome})]

  defp run_ask(prompt, provider) do
    {:ok, session} = Elara.start_session(provider: provider, persist: false)
    {:ok, session_pid} = Elara.session_pid(session)
    ref = Process.monitor(session_pid)
    :ok = Elara.subscribe(session)
    :ok = Elara.ask_async(session, prompt)
    loop(session, session_pid, ref)
  end

  defp loop(session, session_pid, ref) do
    receive do
      {:elara, ^session, event} ->
        IO.write(render(event))

        case event do
          {:turn_ended, {:completed, _}} ->
            :ok

          {:turn_ended, _} ->
            exit({:shutdown, 1})

          {:turn_ended, _outcome, :streamed} ->
            exit({:shutdown, 1})

          _ ->
            loop(session, session_pid, ref)
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
