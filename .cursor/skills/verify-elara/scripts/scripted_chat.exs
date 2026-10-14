# Credential-free persistent chat using the same Elara.Chat.run/3 the Mix task uses.
# Drive passes session settings through env (Mix global switches eat --cwd).
cwd = System.fetch_env!("ELARA_VERIFY_SESSION_CWD") |> Path.expand()
out = System.fetch_env!("ELARA_VERIFY_OUT")

lines =
  System.get_env("ELARA_VERIFY_LINES", "/help,/quit")
  |> String.split(",", trim: true)

persist? = System.get_env("ELARA_VERIFY_PERSIST") == "1"
continue? = System.get_env("ELARA_VERIFY_CONTINUE") == "1"
name = System.get_env("ELARA_VERIFY_NAME")
name = if name in [nil, ""], do: nil, else: name

replies =
  cond do
    (replies = System.get_env("ELARA_VERIFY_REPLIES")) not in [nil, ""] ->
      replies
      |> String.split("||", trim: true)
      |> Enum.map(fn text ->
        {:ok, assistant} = Elara.Message.assistant(text, [])
        {:ok, assistant}
      end)

    (reply = System.get_env("ELARA_VERIFY_REPLY")) not in [nil, ""] ->
      {:ok, assistant} = Elara.Message.assistant(reply, [])
      [{:ok, assistant}]

    true ->
      []
  end

{:ok, agent} = Agent.start_link(fn -> replies end)

session_opts = [
  provider: {Elara.Provider.Scripted, agent},
  cwd: cwd,
  persist: persist?,
  resume: if(continue?, do: :latest, else: nil),
  name: name
]

case Elara.start_session(session_opts) do
  {:ok, session} ->
    initial_messages = length(Elara.transcript(session))
    {:ok, io} = StringIO.open("")
    task = Task.async(fn -> Elara.Chat.run(session, io) end)
    chat = task.pid

    fail = fn message ->
      {_input, body} = StringIO.contents(io)
      File.mkdir_p!(Path.dirname(out))
      File.write!(out, body)
      IO.write(:stderr, "scripted_chat: #{message}\n#{body}\n")
      System.halt(1)
    end

    await_prompt = fn previous_size, attempts ->
      result =
        Enum.reduce_while(1..attempts, nil, fn _, _ ->
          {_input, body} = StringIO.contents(io)

          if byte_size(body) > previous_size and String.ends_with?(body, "> ") and
               match?(%{phase: :idle}, Elara.status(session)) do
            {:halt, {:ok, body}}
          else
            Process.sleep(20)
            {:cont, nil}
          end
        end)

      case result do
        {:ok, body} -> body
        nil -> fail.("did not reach a fresh idle prompt")
      end
    end

    body = await_prompt.(0, 200)
    unless String.contains?(body, "elara  ·  /help"), do: fail.("banner not seen")

    result =
      Enum.reduce_while(lines, body, fn line, previous ->
        send(chat, {:stdin, line <> "\n"})

        if String.trim(line) in ["/quit", "/exit", "/q"] do
          {:halt, :quit}
        else
          {:cont, await_prompt.(byte_size(previous), 250)}
        end
      end)

    if result != :quit do
      send(chat, {:stdin, "/quit\n"})
    end

    code = Task.await(task, 15_000)

    completed =
      session
      |> Elara.transcript()
      |> Enum.drop(initial_messages)
      |> Enum.filter(&match?(%Elara.Message.Assistant{}, &1))
      |> Enum.map(& &1.text)

    expected = Enum.map(replies, fn {:ok, assistant} -> assistant.text end)
    if completed != expected, do: fail.("expected scripted replies were not completed")

    {_input, body} = StringIO.contents(io)
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, body)
    IO.write(body)
    System.halt(code)

  {:error, reason} ->
    message = Elara.Chat.startup_error(reason)
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, message <> "\n")
    IO.write(:stderr, message <> "\n")
    System.halt(1)
end
