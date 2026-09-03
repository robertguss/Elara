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
    replies = System.get_env("ELARA_VERIFY_REPLIES") ->
      if replies == "" do
        []
      else
        replies
        |> String.split("||", trim: true)
        |> Enum.map(fn text ->
          {:ok, assistant} = Elara.Message.assistant(text, [])
          {:ok, assistant}
        end)
      end

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
    {:ok, io} = StringIO.open("")
    task = Task.async(fn -> Elara.Chat.run(session, io) end)
    chat = task.pid

    await_prompt = fn body_so_far, attempts ->
      Enum.reduce_while(1..attempts, body_so_far, fn _, _ ->
        {_input, body} = StringIO.contents(io)

        if String.ends_with?(body, "> ") do
          {:halt, body}
        else
          Process.sleep(20)
          {:cont, body}
        end
      end)
    end

    case await_prompt.("", 200) do
      body when is_binary(body) ->
        if not String.contains?(body, "elara  ·  /help") do
          IO.write(:stderr, "scripted_chat: banner not seen\n#{body}\n")
          System.halt(1)
        end

      _ ->
        IO.write(:stderr, "scripted_chat: did not reach idle prompt\n")
        System.halt(1)
    end

    Enum.each(lines, fn line ->
      send(chat, {:stdin, line <> "\n"})
      _ = await_prompt.("", 250)
    end)

    unless Enum.any?(lines, &(&1 in ["/quit", "/exit", "/q"])) do
      send(chat, {:stdin, "/quit\n"})
    end

    code = Task.await(task, 15_000)
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
