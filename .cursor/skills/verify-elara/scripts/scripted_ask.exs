# Credential-free one-shot ask using the public session API and CLI renderer.
# Driven via env vars — Mix global switches consume --cwd.

cwd = System.fetch_env!("ELARA_VERIFY_SESSION_CWD") |> Path.expand()
out = System.fetch_env!("ELARA_VERIFY_OUT")
prompt = System.get_env("ELARA_VERIFY_PROMPT", "summarize this workspace")
reply = System.get_env("ELARA_VERIFY_REPLY", "workspace contains README.md")
persist? = System.get_env("ELARA_VERIFY_PERSIST") == "1"
name = System.get_env("ELARA_VERIFY_NAME")
name = if name in [nil, ""], do: nil, else: name
tool = System.get_env("ELARA_VERIFY_TOOL")
tool = if tool in [nil, ""], do: nil, else: tool
path = System.get_env("ELARA_VERIFY_PATH")
content = System.get_env("ELARA_VERIFY_CONTENT")

{:ok, assistant} = Elara.Message.assistant(reply, [])

replies =
  case tool do
    "write" ->
      call = %Elara.Message.ToolCall{
        id: "verify-write-1",
        name: "write",
        args: {:ok, %{"path" => path, "content" => content}}
      }

      {:ok, first} = Elara.Message.assistant(nil, [call])
      [{:ok, first}, {:ok, assistant}]

    "read" ->
      call = %Elara.Message.ToolCall{
        id: "verify-read-1",
        name: "read",
        args: {:ok, %{"path" => path}}
      }

      {:ok, first} = Elara.Message.assistant(nil, [call])
      [{:ok, first}, {:ok, assistant}]

    "bash" ->
      call = %Elara.Message.ToolCall{
        id: "verify-bash-1",
        name: "bash",
        args: {:ok, %{"command" => content}}
      }

      {:ok, first} = Elara.Message.assistant(nil, [call])
      [{:ok, first}, {:ok, assistant}]

    nil ->
      [{:ok, assistant}]

    other ->
      Mix.shell().error("scripted_ask: unsupported ELARA_VERIFY_TOOL #{other}")
      System.halt(1)
  end

{:ok, agent} = Agent.start_link(fn -> replies end)

session_opts = [
  provider: {Elara.Provider.Scripted, agent},
  cwd: cwd,
  persist: persist?
]

session_opts = if is_binary(name), do: Keyword.put(session_opts, :name, name), else: session_opts

{:ok, session} = Elara.start_session(session_opts)
:ok = Elara.subscribe(session)
:ok = Elara.ask_async(session, prompt)

{:ok, io} = StringIO.open("")

halt =
  Stream.repeatedly(fn ->
    receive do
      {:elara, ^session, event} ->
        iodata = Elara.CLI.render(event)
        IO.write(io, iodata)
        IO.write(iodata)

        case event do
          {:turn_ended, {:completed, _}} -> {:halt, 0}
          {:turn_ended, {:completed, _}, :streamed} -> {:halt, 0}
          {:turn_ended, _outcome} -> {:halt, 1}
          {:turn_ended, _outcome, :streamed} -> {:halt, 1}
          _ -> :cont
        end
    after
      60_000 ->
        IO.write(:stderr, "scripted_ask: timed out waiting for turn\n")
        {:halt, 1}
    end
  end)
  |> Enum.find_value(fn
    {:halt, code} -> code
    :cont -> nil
  end)

{_input, body} = StringIO.contents(io)
File.mkdir_p!(Path.dirname(out))
File.write!(out, body)
System.halt(halt)
