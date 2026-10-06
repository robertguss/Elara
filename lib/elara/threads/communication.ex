defmodule Elara.Threads.Communication do
  @moduledoc "Durable related-thread transport. This actor never calls a model."
  use GenServer
  alias Elara.{Message, Threads}
  alias Elara.Session.Store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def send_message(sender, recipient, id, text),
    do: GenServer.call(__MODULE__, {:send, sender, recipient, id, text}, :infinity)

  def status(sender, recipient), do: GenServer.call(__MODULE__, {:status, sender, recipient})

  def wait(sender, recipient) do
    with {:ok, response} <- Elara.Completion.wait(sender, "thread", recipient),
         {:ok, status} <- status(sender, recipient),
         do: {:ok, Map.merge(status, response)}
  end

  def subscribe_completion(sender, recipient),
    do: GenServer.call(__MODULE__, {:subscribe_completion, sender, recipient}, :infinity)

  def lifecycle(store, {:turn_ended, outcome, _}), do: lifecycle(store, {:turn_ended, outcome})

  def lifecycle(store, {:turn_ended, outcome}) do
    # Stage evidence before notifying another actor. A transport restart cannot lose it.
    report(store, outcome)
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:completed, store, outcome})
    :ok
  catch
    :exit, _ -> :ok
  end

  def lifecycle(_, _), do: :ok

  def tools do
    for {name, description, required} <- [
          {"thread_send",
           "Send a nonempty agent message/follow-up to an existing direct child or parent. Supply a stable message_id; identical retries deduplicate. Does not steer, grant capabilities, or resume stopped input.",
           ["thread_id", "message_id", "text"]},
          {"thread_read",
           "Read/search original related-thread evidence. Source IDs and active-branch membership identify revisions. Use offset/character_offset for bounded pages; summaries never replace originals.",
           ["thread_id"]},
          {"thread_status",
           "Inspect direct parent/child lifecycle and durable delivery receipts.", ["thread_id"]},
          {"thread_wait",
           "Wait for one related-thread completion through the correlated inbox, without model polling. The wait consumes that report once. Interrupt cancels waiting; do not send empty acknowledgements.",
           ["thread_id"]}
        ] do
      %Elara.Tool{
        name: name,
        description: description,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "thread_id" => %{"type" => "string"},
            "message_id" => %{"type" => "string"},
            "source_message_id" => %{"type" => "string"},
            "text" => %{"type" => "string"},
            "query" => %{"type" => "string"},
            "offset" => %{"type" => "integer", "minimum" => 0},
            "character_offset" => %{"type" => "integer", "minimum" => 0}
          },
          "required" => required
        },
        run: {if(name == "thread_wait", do: Elara.Completion, else: __MODULE__), :run},
        capabilities: [],
        placement: :local,
        mutating: name == "thread_send"
      }
    end
  end

  def run(args, %Elara.Tool.Ctx{session_id: sender, tool_name: name}) do
    result =
      case name do
        "thread_send" -> send_message(sender, args["thread_id"], args["message_id"], args["text"])
        "thread_status" -> status(sender, args["thread_id"])
        "thread_wait" -> wait(sender, args["thread_id"])
        "thread_read" -> read_messages(sender, args["thread_id"], args)
      end

    case result do
      {:ok, value} -> {:ok, JSON.encode!(value)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def read_messages(sender, target, opts \\ %{})

  def read_messages(sender, target, %{"message_id" => id} = opts) when is_binary(id) do
    with true <- Threads.related?(sender, target),
         {:ok, message} <-
           load(
             Path.join(
               root(),
               digest({target, Elara.Session.Handoff.logical_id(sender), id}) <> ".json"
             )
           ),
         offset when is_integer(offset) and offset >= 0 <- Map.get(opts, "character_offset", 0) do
      text = JSON.encode!(message["evidence"] || %{"text" => message["text"]})
      page = String.slice(text, offset, 2048)

      {:ok,
       %{
         thread_id: target,
         message_id: id,
         source_message_id: get_in(message, ["evidence", "source_message_id"]),
         character_offset: offset,
         text: page,
         next_character_offset:
           if(offset + String.length(page) < String.length(text),
             do: offset + String.length(page)
           )
       }}
    else
      false -> {:error, :unrelated_thread}
      {:error, _} = error -> error
      _ -> {:error, :invalid_read_range}
    end
  end

  def read_messages(sender, target, opts) do
    with true <- Threads.related?(sender, target),
         {:ok, store} <- thread_store(target),
         offset when is_integer(offset) and offset >= 0 <- Map.get(opts, "offset", 0),
         char_offset when is_integer(char_offset) and char_offset >= 0 <-
           Map.get(opts, "character_offset", 0),
         query when is_binary(query) <- Map.get(opts, "query", "") do
      active = ancestors(store.leaf, Map.new(store.entries, &{&1.id, &1.parent_id}))

      entries =
        Enum.filter(
          store.entries,
          &(String.contains?(evidence_text(&1.message), query) and
              (is_nil(opts["source_message_id"]) or &1.id == opts["source_message_id"]))
        )

      case Enum.at(entries, offset) do
        nil ->
          {:ok, %{entries: [], total: length(entries)}}

        entry ->
          text = evidence_text(entry.message)
          page = String.slice(text, char_offset, 2048)

          {:ok,
           %{
             thread_id: target,
             source_message_id: entry.id,
             parent_message_id: entry.parent_id,
             active_revision: entry.id in active,
             later_revisions_exist: entry.id != store.leaf,
             later_message_ids:
               store.entries
               |> Enum.drop_while(&(&1.id != entry.id))
               |> Enum.drop(1)
               |> Enum.take(8)
               |> Enum.map(& &1.id),
             offset: offset,
             character_offset: char_offset,
             next_character_offset:
               if(char_offset + String.length(page) < String.length(text),
                 do: char_offset + String.length(page)
               ),
             total: length(entries),
             text: page
           }}
      end
    else
      false -> {:error, :unrelated_thread}
      {:error, _} = error -> error
      _ -> {:error, :invalid_read_range}
    end
  end

  defp evidence_text(%Message.Assistant{} = a),
    do:
      JSON.encode!(%{
        role: "assistant",
        text: a.text,
        public_content: a.public_content,
        tool_calls:
          Enum.map(
            a.tool_calls,
            &%{
              id: &1.id,
              name: &1.name,
              args: inspect(&1.args, limit: :infinity, printable_limit: :infinity)
            }
          )
      })

  defp evidence_text(%Message.User{} = user),
    do:
      JSON.encode!(%{
        role: if(user.agent_source, do: "agent_message", else: "owner"),
        text: user.text,
        agent_source: user.agent_source,
        attachments: Enum.map(user.attachments, &Elara.Attachment.metadata/1)
      })

  defp evidence_text(message), do: JSON.encode!(Store.encode_message(message))
  defp ancestors(nil, _), do: []
  defp ancestors(id, parents), do: [id | ancestors(Map.get(parents, id), parents)]

  def thread_store(id) do
    case Elara.session_pid(id) do
      {:ok, pid} ->
        {:ok, GenServer.call(pid, :thread_store)}

      _ ->
        case Threads.record(id) do
          {:ok, r} ->
            Store.open(r["session_path"])

          _ ->
            case Enum.find(Threads.all_records(), &(&1["parent_id"] == id)) do
              nil ->
                Elara.Session.Handoff.store(id)

              r ->
                with {:ok, info} <- Store.find(r["parent_invocation_cwd"] || r["parent_cwd"], id),
                     do: Store.open(info.path)
            end
        end
    end
  catch
    :exit, _ -> {:error, :thread_unavailable}
  end

  @impl true
  def init(_) do
    send(self(), :recover)
    {:ok, %{waiters: %{}}}
  end

  @impl true
  def handle_call({:send, sender, recipient, id, text}, _from, state) do
    result =
      with true <- sender != recipient and Threads.related?(sender, recipient),
           true <- is_binary(id) and byte_size(id) in 1..128,
           true <-
             is_binary(text) and String.valid?(text) and String.trim(text) != "" and
               byte_size(text) <= 65_536 do
        accept(sender, recipient, id, text, "agent", nil)
      else
        _ -> {:error, :invalid_or_unrelated_message}
      end

    send(self(), :flush)
    {:reply, result, state}
  end

  def handle_call({:status, sender, recipient}, _from, state),
    do: {:reply, status_view(sender, recipient), state}

  def handle_call({:subscribe_completion, sender, recipient}, {caller, _}, state) do
    with true <-
           Elara.Session.Handoff.logical_id(sender) != Elara.Session.Handoff.logical_id(recipient) and
             Threads.related?(sender, recipient),
         true <- Process.alive?(caller),
         {:ok, status} <- status_view(sender, recipient),
         {:ok, store} <- thread_store(Elara.Session.Handoff.owner(recipient)) do
      correlation = Elara.Completion.thread_correlation(store)
      leaf = Enum.find(store.entries, &(&1.id == store.leaf))

      terminal =
        case {status.phase, leaf} do
          {phase,
           %Store.Entry{message: %Message.Assistant{tool_calls: [], interrupted: false} = message}}
          when phase in ["idle", "completed"] ->
            {:completed, message.text}

          {phase, _} when phase in ["failed", "interrupted"] ->
            String.to_existing_atom(phase)

          _ ->
            nil
        end

      cond do
        status.phase == "idle" and is_nil(terminal) ->
          {:reply, {:idle, status}, state}

        status.phase == "unavailable" or is_nil(correlation) ->
          {:reply, {:error, :thread_unavailable}, state}

        terminal ->
          report(store, terminal, sender)
          send(self(), :flush)
          {:reply, {:ok, correlation, self()}, state}

        status.phase == "completed" ->
          {:reply, {:error, :thread_unavailable}, state}

        true ->
          {:ok, target} = Elara.session_pid(Elara.Session.Handoff.owner(recipient))
          ref = Process.monitor(caller)

          waiter = %{
            sender: sender,
            target: recipient,
            correlation: correlation,
            target_ref: Process.monitor(target)
          }

          {:reply, {:ok, correlation, self()}, put_in(state.waiters[ref], waiter)}
      end
    else
      false -> {:reply, {:error, :unrelated_thread}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_cast({:completed, store, outcome}, state) do
    correlation = Elara.Completion.thread_correlation(store)

    waiters =
      Enum.reduce(state.waiters, %{}, fn {ref, waiter}, acc ->
        if waiter.correlation == correlation do
          report(store, outcome, waiter.sender)
          Process.demonitor(ref, [:flush])
          Process.demonitor(waiter.target_ref, [:flush])
          acc
        else
          Map.put(acc, ref, waiter)
        end
      end)

    flush_reports()
    send(self(), :flush)
    {:noreply, %{state | waiters: waiters}}
  end

  @impl true
  def handle_info(:recover, state) do
    # Reconcile persisted completion after a crash between transcript and notification.
    for r <- Threads.all_records(),
        {:ok, store} <- [thread_store(Elara.Session.Handoff.owner(r["id"]))],
        not Elara.Session.Handoff.frozen?(store),
        store.context["source"] == nil or store.context["activated"] == true,
        %Store.Entry{message: %Message.Assistant{tool_calls: [], text: text} = assistant} <- [
          Enum.find(store.entries, &(&1.id == store.leaf))
        ],
        is_binary(text) do
      report(store, if(assistant.interrupted, do: :interrupted, else: {:completed, text}))
    end

    send(self(), :deliver)
    {:noreply, state}
  end

  def handle_info(:deliver, state) do
    flush_reports()
    flush()
    Process.send_after(self(), :deliver, 1000)
    {:noreply, state}
  end

  def handle_info(:flush, state) do
    flush()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, stopped, _}, state) do
    waiters =
      Enum.reduce(state.waiters, %{}, fn {caller_ref, waiter}, acc ->
        cond do
          ref == caller_ref ->
            Process.demonitor(waiter.target_ref, [:flush])
            acc

          ref == waiter.target_ref ->
            owner = Elara.Session.Handoff.owner(waiter.target)

            case Elara.session_pid(owner) do
              {:ok, target} when owner != waiter.target and target != stopped ->
                Map.put(acc, caller_ref, %{waiter | target_ref: Process.monitor(target)})

              _ ->
                Process.demonitor(caller_ref, [:flush])

                case Elara.session_pid(Elara.Session.Handoff.owner(waiter.sender)) do
                  {:ok, receiver} ->
                    send(receiver, {:completion_disconnected, waiter.correlation})

                  _ ->
                    :ok
                end

                acc
            end

          true ->
            Map.put(acc, caller_ref, waiter)
        end
      end)

    {:noreply, %{state | waiters: waiters}}
  end

  defp report(store, outcome, recipient \\ nil) do
    active = Enum.find(store.inbox, &(&1.id == store.active_input_id))
    last_user = store.entries |> Enum.reverse() |> Enum.find(&match?(%Message.User{}, &1.message))

    report_input? =
      (active && active.kind == :report) ||
        (last_user &&
           Enum.any?(store.inbox, &(&1.kind == :report and &1.user == last_user.message)))

    original = Enum.find(Elara.Session.Handoff.lineage(store.id), &Threads.managed?/1)

    with false <- is_nil(recipient) and !!report_input?,
         true <- not is_nil(recipient) or not is_nil(original),
         {:ok, r} <- if(is_nil(original), do: {:ok, %{}}, else: Threads.record(original)) do
      result =
        case outcome do
          {:completed, text} -> text
          other -> inspect(other, limit: :infinity, printable_limit: :infinity)
        end

      evidence = %{
        "result" => result,
        "workspace" => store.cwd,
        "source_thread_id" => store.id,
        "source_message_id" => store.leaf,
        "session_path" => store.path,
        "file_change_caveat" =>
          "Referenced write/edit requests are not proof of changed bytes. Consult their linked results; bash/plugin and manual changes are not inferred.",
        "changed_files" =>
          for(
            %Store.Entry{id: source, message: %Message.Assistant{tool_calls: calls}} <-
              store.entries,
            call <- calls,
            call.name in ["write", "edit"],
            {:ok, args} <- [call.args],
            do: %{"path" => args["path"], "source_message_id" => source, "call_id" => call.id}
          ),
        "tools_and_tests" =>
          for(
            %Store.Entry{id: source, message: %Message.ToolResult{} = result} <- store.entries,
            do: %{
              "source_message_id" => source,
              "call_id" => result.call_id,
              "tool" => result.name
            }
          ),
        "failure_or_uncertainty" =>
          if(match?({:completed, _}, outcome),
            do: "Child-reported completion, not independent verification",
            else: result
          )
      }

      id = "completion:#{store.leaf}"
      recipient = Elara.Session.Handoff.logical_id(recipient || r["parent_id"])
      key = digest({store.id, recipient, id})
      path = Path.join([root(), "completions", key <> ".json"])

      if not File.exists?(path) do
        write_json(path, %{
          "sender" => store.id,
          "recipient" => recipient,
          "id" => id,
          "text" => result || "No textual result",
          "evidence" => evidence,
          "correlation" => Elara.Completion.thread_correlation(store)
        })
      end
    end
  end

  defp flush_reports do
    for path <- Path.wildcard(Path.join([root(), "completions", "*.json"])),
        not match?(
          {:ok, %{"correlation" => %{}}},
          load(Path.join(root(), Path.basename(path)))
        ),
        {:ok, r} <- [load(path)] do
      correlation =
        r["correlation"] ||
          with {:ok, store} <- thread_store(r["sender"]),
               %{"source_message_id" => leaf} <- r["evidence"],
               %Store.Entry{} <- Enum.find(store.entries, &(&1.id == leaf)) do
            Elara.Completion.thread_correlation(%{
              store
              | leaf: leaf,
                completion_occurrence: nil
            })
          else
            _ -> nil
          end

      accept(
        r["sender"],
        r["recipient"],
        r["id"],
        r["text"],
        "report",
        r["evidence"],
        correlation
      )
    end
  end

  defp accept(sender, recipient, id, text, kind, evidence, correlation \\ nil) do
    recipient = Elara.Session.Handoff.logical_id(recipient)
    key = digest({sender, recipient, id})
    existing = load(Path.join(root(), key <> ".json"))

    cond do
      match?({:ok, _}, existing) ->
        {:ok, old} = existing

        previous = old["correlation"]

        if old["text"] == text and old["kind"] == kind and old["evidence"] == evidence and
             (previous == correlation or is_nil(previous) or is_nil(correlation)) do
          if is_nil(previous) and not is_nil(correlation) do
            updated = old |> Map.put("correlation", correlation) |> Map.put("delivery", "pending")
            with :ok <- save(updated), do: {:ok, receipt(updated)}
          else
            {:ok, receipt(old)}
          end
        else
          {:error, :message_id_conflict}
        end

      Enum.count(messages(), &(&1["recipient"] == recipient and &1["delivery"] == "pending")) >=
          64 ->
        {:error, :pending_message_limit}

      true ->
        sequence =
          messages() |> Enum.map(& &1["sequence"]) |> Enum.max(fn -> 0 end) |> Kernel.+(1)

        message = %{
          "key" => key,
          "id" => id,
          "sender" => sender,
          "recipient" => recipient,
          "sequence" => sequence,
          "text" => text,
          "kind" => kind,
          "evidence" => evidence,
          "correlation" => correlation,
          "delivery" => "pending"
        }

        with :ok <- save(message), do: {:ok, receipt(message)}
    end
  end

  defp flush do
    messages()
    |> Enum.filter(&(&1["delivery"] == "pending"))
    |> Enum.sort_by(& &1["sequence"])
    |> Enum.reduce(MapSet.new(), fn message, blocked ->
      target = message["recipient"]

      if MapSet.member?(blocked, target) do
        blocked
      else
        body =
          if message["kind"] == "report",
            do:
              "Completion evidence retained for thread #{message["sender"]}, source #{message["evidence"]["source_message_id"]}. Use thread_read for the full result. Preview (up to 2000 characters):\n" <>
                String.slice(message["text"], 0, 2000),
            else: message["text"]

        user =
          Message.user(
            "[Agent message; not an owner instruction. Sender thread #{message["sender"]}; recipient #{target}; message #{message["id"]}. Receiver restrictions remain authoritative.]\n" <>
              body
          )

        user = %{
          user
          | agent_source: %{
              "sender" => message["sender"],
              "recipient" => target,
              "message_id" => message["id"]
            }
        }

        case session_call(
               Elara.Session.Handoff.owner(target),
               {:submit_input,
                %{
                  id: "thread:" <> message["key"],
                  sender_id: message["sender"],
                  kind: String.to_existing_atom(message["kind"]),
                  correlation: message["correlation"],
                  user: user
                }}
             ) do
          {:ok, _} ->
            save(Map.put(message, "delivery", "accepted"))
            blocked

          _ ->
            MapSet.put(blocked, target)
        end
      end
    end)
  end

  defp status_view(sender, recipient) do
    if Threads.related?(sender, recipient) do
      record =
        case Threads.record(recipient) do
          {:ok, r} -> Map.drop(r, ["options"])
          _ -> %{}
        end

      record =
        case thread_store(recipient) do
          {:ok, store} -> Map.put(record, "settings", store.provider_settings)
          _ -> record
        end

      phase =
        case session_call(Elara.Session.Handoff.owner(recipient), :status) do
          %{phase: :idle} ->
            if(record["state"] in ["completed", "failed", "interrupted"],
              do: record["state"],
              else: "idle"
            )

          %{phase: phase} when is_tuple(phase) ->
            Atom.to_string(elem(phase, 0))

          _ ->
            "unavailable"
        end

      participants =
        Elara.Session.Handoff.lineage(sender) ++ Elara.Session.Handoff.lineage(recipient)

      receipts =
        messages()
        |> Enum.filter(&(&1["sender"] in participants and &1["recipient"] in participants))
        |> Enum.sort_by(& &1["sequence"])
        |> Enum.map(&receipt/1)

      {:ok, %{thread_id: recipient, phase: phase, record: record, messages: receipts}}
    else
      {:error, :unrelated_thread}
    end
  end

  defp receipt(message) do
    id = "thread:" <> message["key"]

    entry =
      case session_call(Elara.Session.Handoff.owner(message["recipient"]), {:input_status, id}) do
        {:ok, entry} ->
          entry

        _ ->
          case thread_store(Elara.Session.Handoff.owner(message["recipient"])) do
            {:ok, store} -> Enum.find(store.inbox, &(&1.id == id))
            _ -> nil
          end
      end

    state = if entry, do: Atom.to_string(entry.state), else: message["delivery"]

    Map.take(message, ~w(id sender recipient sequence kind)) |> Map.put("delivery", state)
  end

  defp session_call(id, command) do
    with {:ok, pid} <- Elara.session_pid(id), do: GenServer.call(pid, command)
  catch
    :exit, _ -> {:error, :thread_unavailable}
  end

  defp digest(term),
    do: Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(term)), case: :lower)

  defp root do
    {:ok, root} = Store.root()
    Path.join(root, "_thread_messages")
  end

  defp messages,
    do:
      Path.wildcard(Path.join(root(), "*.json"))
      |> Enum.flat_map(fn p ->
        case load(p) do
          {:ok, m} -> [m]
          _ -> []
        end
      end)

  defp load(path), do: with({:ok, bytes} <- File.read(path), do: JSON.decode(bytes))

  defp save(message) do
    path = Path.join(root(), message["key"] <> ".json")
    write_json(path, message)
  end

  defp write_json(path, message) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, JSON.encode!(message)),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path),
         do: :ok
  end
end
