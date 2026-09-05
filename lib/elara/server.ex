defmodule Elara.Server do
  @moduledoc "Local TCP gateway for detachable sessions."

  use GenServer

  alias Elara.Protocol

  @default_port 4_048
  @max_packet_bytes Protocol.max_line_bytes()
  @protocol_versions Protocol.versions()

  @doc false
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start(__MODULE__, opts)
      name -> GenServer.start(__MODULE__, opts, name: name)
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec port(pid()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    provider = Keyword.get(opts, :provider)
    lifetime = Keyword.get(opts, :lifetime, :long_lived)

    listen_opts = [
      :binary,
      packet: :line,
      packet_size: @max_packet_bytes,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1}
    ]

    case :gen_tcp.listen(port, listen_opts) do
      {:ok, listen} ->
        {:ok, actual_port} = :inet.port(listen)
        acceptor = spawn_link(fn -> accept_loop(listen, provider, lifetime) end)
        {:ok, %{listen: listen, port: actual_port, acceptor: acceptor}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    :ok
  end

  defp accept_loop(listen, provider, lifetime) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {:ok, pid} =
          Task.Supervisor.start_child(Elara.TaskSup, fn ->
            receive do
              {:socket, socket} -> connection(socket, provider, lifetime)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, {:socket, socket})
        accept_loop(listen, provider, lifetime)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listen, provider, lifetime)
    end
  end

  defp connection(socket, provider, lifetime) do
    with {:ok, line} <- recv_line(socket, 30_000),
         {:ok, request} <- Protocol.decode(line) do
      establish_connection(socket, provider, lifetime, request)
    else
      {:error, reason} -> send_error(socket, reason, Protocol.version())
    end

    :gen_tcp.close(socket)
  end

  defp establish_connection(socket, provider, lifetime, request) do
    version = response_version(request)
    extensions = Map.get(request, "extensions", [])

    Process.put(
      :input_attachments,
      version == 2 and is_list(extensions) and "input_attachments_v1" in extensions
    )

    Process.put(:input_images, %{})

    Process.put(
      :input_queue,
      version == 2 and is_list(extensions) and "input_queue_v1" in extensions
    )

    Process.put(
      :provider_visibility,
      version == 2 and is_list(extensions) and "provider_visibility_v1" in extensions
    )

    case request do
      %{"version" => 2, "command" => "list"} = request ->
        case decode_cwd(Map.get(request, "cwd", File.cwd!())) do
          {:ok, cwd} -> send_json(socket, legacy_sessions_message(cwd))
          {:error, reason} -> send_error(socket, reason, version)
        end

      _request ->
        with {:ok, version, session, mode, cursor, incarnation} <-
               prepare_attachment(request, provider),
             {:ok, session_pid} <- Elara.session_pid(session),
             {:ok, attachment} <- attach(version, session_pid, mode, cursor, incarnation) do
          Process.monitor(session_pid)

          send_json(
            socket,
            Map.put(
              attached_message(version, mode, attachment, lifetime)
              |> Map.put("cwd", Elara.cwd(session)),
              "extensions",
              Enum.filter(["provider_visibility_v1", "input_attachments_v1", "input_queue_v1"], fn
                "provider_visibility_v1" -> Process.get(:provider_visibility)
                "input_attachments_v1" -> Process.get(:input_attachments)
                "input_queue_v1" -> Process.get(:input_queue)
              end)
            )
          )

          if version == 1 do
            Enum.each(attachment.replay, fn {seq, event} ->
              send_v1_event(socket, seq, event)
            end)
          end

          :ok = :inet.setopts(socket, active: :once)
          connection_loop(socket, session, version, Protocol.line_buffer(), provider, lifetime)
        else
          {:error, reason} -> send_error(socket, reason, version)
        end
    end
  end

  defp prepare_attachment(%{"version" => version}, _provider)
       when version not in @protocol_versions,
       do: {:error, :unsupported_version}

  defp prepare_attachment(%{"version" => version, "command" => "create"} = request, provider) do
    mode = decode_mode(Map.get(request, "mode", "control"))

    with {:ok, mode} <- mode,
         {:ok, cwd} <- decode_cwd(Map.get(request, "cwd", File.cwd!())),
         {:ok, provider} <- resolve_provider(provider),
         {:ok, session} <- Elara.start_session(provider: provider, cwd: cwd) do
      {:ok, version, session, mode, 0, nil}
    end
  end

  defp prepare_attachment(
         %{"version" => version, "command" => "attach", "session_id" => session} = request,
         provider
       )
       when is_binary(session) do
    with {:ok, mode} <- decode_mode(Map.get(request, "mode", "control")),
         {:ok, cursor} <- decode_cursor(Map.get(request, "cursor", 0)),
         {:ok, cwd} <- decode_optional_cwd(Map.get(request, "cwd")),
         {:ok, session} <- ensure_live_session(session, cwd, provider) do
      {:ok, version, session, mode, cursor, Map.get(request, "incarnation")}
    end
  end

  defp prepare_attachment(_request, _provider), do: {:error, :invalid_command}

  defp attach(1, session, mode, cursor, incarnation),
    do: Elara.attach(session, mode, cursor, incarnation)

  defp attach(2, session, mode, cursor, incarnation),
    do: Elara.attach_v2(session, mode, cursor, incarnation)

  defp attached_message(1, mode, attachment, lifetime) do
    %{
      "type" => "attached",
      "version" => 1,
      "session_id" => attachment.id,
      "incarnation" => attachment.incarnation,
      "head" => attachment.head,
      "mode" => Atom.to_string(mode),
      "lifetime" => Atom.to_string(lifetime)
    }
  end

  defp attached_message(2, mode, attachment, lifetime) do
    %{
      "type" => "attached",
      "version" => 2,
      "session_id" => attachment.id,
      "incarnation" => attachment.incarnation,
      "head" => attachment.head,
      "mode" => Atom.to_string(mode),
      "snapshot" => negotiated_snapshot(attachment.snapshot),
      "lifetime" => Atom.to_string(lifetime)
    }
  end

  defp legacy_sessions_message(cwd) do
    sessions = lifecycle_sessions(cwd)
    %{"type" => "sessions", "version" => 2, "sessions" => sessions}
  end

  defp lifecycle_sessions(cwd) do
    cwd = Path.expand(cwd)

    saved =
      Map.new(Elara.Session.Store.list(cwd, include_empty: true), fn info ->
        {info.id,
         %{
           "id" => info.id,
           "name" => info.name,
           "cwd" => info.cwd,
           "state" => "saved",
           "updated_at" => info.timestamp * 1_000,
           "head" => info.head,
           "model" => info.model
         }}
      end)

    sessions =
      Elara.live_sessions()
      |> Enum.filter(&(&1.cwd == cwd))
      |> Enum.reduce(saved, fn status, sessions ->
        Map.put(sessions, status.id, %{
          "id" => status.id,
          "incarnation" => status.incarnation,
          "name" => status.name,
          "cwd" => status.cwd,
          "state" => phase_name(status.phase),
          "updated_at" => status.updated_at,
          "head" => status.event_head,
          "provider" => status.provider,
          "model" => status.model
        })
      end)

    sessions |> Map.values() |> Enum.sort_by(&{-&1["updated_at"], &1["id"]})
  end

  defp phase_name(:idle), do: "idle"
  defp phase_name({:calling_provider, _ref, _iteration}), do: "calling_provider"
  defp phase_name({:running_tool, _ref, _call, _remaining, _iteration}), do: "running_tool"

  defp connection_loop(socket, session, version, line_buffer, provider, lifetime) do
    receive do
      {:tcp, ^socket, chunk} ->
        case Protocol.push_line(line_buffer, chunk) do
          {:ok, line} ->
            response =
              handle_command(
                session,
                version,
                Protocol.decode(line),
                provider,
                lifetime
              )

            send_json(socket, response)
            :ok = :inet.setopts(socket, active: :once)
            connection_loop(socket, session, version, Protocol.line_buffer(), provider, lifetime)

          {:more, line_buffer} ->
            :ok = :inet.setopts(socket, active: :once)
            connection_loop(socket, session, version, line_buffer, provider, lifetime)

          {:error, reason} ->
            send_error(socket, reason, version)
        end

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _reason} ->
        :ok

      {:DOWN, _ref, :process, _pid, _reason} ->
        :ok

      {:elara_event, ^session, incarnation, seq, event} ->
        case send_v1_event(socket, seq, event, incarnation) do
          :ok -> connection_loop(socket, session, version, line_buffer, provider, lifetime)
          {:error, _} -> :ok
        end

      {:elara_patch, ^session, incarnation, seq, ops} ->
        ops =
          if Process.get(:provider_visibility),
            do: ops,
            else: Enum.reject(ops, &(&1["op"] == "set_provider_view"))

        ops =
          if Process.get(:input_queue),
            do: ops,
            else: Enum.reject(ops, &(&1["op"] == "set_inbox"))

        message = Protocol.patch(seq, ops) |> Map.put("incarnation", incarnation)

        case send_json(socket, message) do
          :ok -> connection_loop(socket, session, version, line_buffer, provider, lifetime)
          {:error, _} -> :ok
        end
    end
  end

  defp send_v1_event(socket, seq, event, incarnation \\ nil)
  defp send_v1_event(_socket, _seq, :provider_view_changed, _incarnation), do: :ok
  defp send_v1_event(_socket, _seq, :inbox_changed, _incarnation), do: :ok

  defp send_v1_event(socket, seq, event, incarnation) do
    message = Protocol.event(seq, event)
    message = if incarnation, do: Map.put(message, "incarnation", incarnation), else: message
    send_json(socket, message)
  end

  defp negotiated_snapshot(snapshot) do
    snapshot =
      if Process.get(:provider_visibility),
        do: snapshot,
        else: Map.delete(snapshot, "provider_view")

    if Process.get(:input_queue), do: snapshot, else: Map.delete(snapshot, "inbox")
  end

  defp handle_command(
         session,
         version,
         {:ok, %{"version" => version} = request},
         provider,
         lifetime
       ),
       do: handle_versioned_command(session, version, request, provider, lifetime)

  defp handle_command(_session, version, {:ok, _request}, _provider, _lifetime),
    do: error_message(:unsupported_version, version)

  defp handle_command(_session, version, {:error, reason}, _provider, _lifetime),
    do: error_message(reason, version)

  defp handle_versioned_command(session, 2, %{"command" => command} = request, provider, lifetime)
       when command in [
              "session_list",
              "session_create",
              "session_name",
              "session_delete",
              "session_tree",
              "session_fork",
              "session_clone",
              "session_reload",
              "child_start",
              "child_list",
              "child_integrate",
              "child_cleanup",
              "child_stop_subtree"
            ] do
    lifecycle_command(session, command, request, provider, lifetime)
  end

  defp handle_versioned_command(
         session,
         2,
         %{"command" => command, "extension" => "input_queue_v1"} = request,
         _provider,
         _lifetime
       )
       when command in ["submit_input", "cancel_input", "resume_inputs", "input_status"] do
    if Process.get(:input_queue) do
      queue_command(session, command, request)
    else
      input_receipt(command, request["submission_id"], nil, :unsupported_extension)
    end
  end

  defp handle_versioned_command(
         session,
         2,
         %{
           "command" => "set_provider_settings",
           "extension" => "provider_visibility_v1",
           "model" => model,
           "effort" => effort
         },
         _provider,
         _lifetime
       ) do
    if Process.get(:provider_visibility) do
      command_result(
        Elara.attached_command(
          session,
          {:provider_settings, %{"model" => model, "effort" => effort}}
        ),
        2
      )
    else
      error_message(:unsupported_extension, 2)
    end
  end

  defp handle_versioned_command(
         session,
         2,
         %{"command" => command, "extension" => "input_attachments_v1"} = request,
         _provider,
         _lifetime
       )
       when command in ["discover_files", "ingest_image", "discard_attachment", "ask"] do
    result =
      if Process.get(:input_attachments) do
        with {:ok, cwd} <- Elara.attached_command(session, :input_workspace) do
          input_command(session, cwd, command, request)
        end
      else
        {:error, :unsupported_extension}
      end

    response =
      case result do
        {:ok, payload} -> Map.merge(%{"type" => "ok", "version" => 2}, payload)
        :ok -> %{"type" => "ok", "version" => 2}
        {:error, reason} -> error_message(reason, 2)
      end

    response |> Map.put("command", command) |> Map.put("request_id", request["request_id"])
  end

  defp handle_versioned_command(
         session,
         version,
         %{"command" => "ask", "prompt" => prompt} = request,
         _provider,
         _lifetime
       )
       when is_binary(prompt) do
    if Map.has_key?(request, "references") or Map.has_key?(request, "attachment_ids") do
      error_message(:unsupported_extension, version)
    else
      command_result(Elara.attached_command(session, {:ask, prompt}), version)
    end
  end

  defp handle_versioned_command(
         session,
         version,
         %{"command" => "interrupt"},
         _provider,
         _lifetime
       ) do
    command_result(Elara.attached_command(session, :interrupt), version)
  end

  defp handle_versioned_command(session, version, %{"command" => "inspect"}, _provider, _lifetime) do
    case Elara.status(session) do
      %{} = status ->
        %{
          "type" => "status",
          "version" => version,
          "status" => json_status(status),
          "why" => inspect(Elara.why(session), pretty: true, limit: 100)
        }

      {:error, reason} ->
        error_message(reason, version)
    end
  end

  defp handle_versioned_command(session, 2, %{"command" => "resnapshot"}, _provider, _lifetime) do
    case Elara.snapshot(session) do
      %{} = snapshot -> snapshot_message(snapshot)
      {:error, reason} -> error_message(reason, 2)
    end
  end

  defp handle_versioned_command(_session, version, _request, _provider, _lifetime),
    do: error_message(:invalid_command, version)

  defp lifecycle_command(session, command, request, provider, lifetime) do
    result =
      with {:ok, cwd} <- lifecycle_cwd(session, command) do
        run_lifecycle_command(session, command, request, provider, cwd, lifetime)
      end

    case result do
      {:ok, response} -> response
      {:error, reason} -> session_error(command, reason)
    end
  end

  defp lifecycle_cwd(session, command)
       when command in ["session_list", "session_tree", "child_list"],
       do: {:ok, Elara.cwd(session)}

  defp lifecycle_cwd(session, _command),
    do: Elara.attached_command(session, :input_workspace)

  defp run_lifecycle_command(session, "child_start", request, _provider, _cwd, _lifetime) do
    with {:ok, child} <-
           Elara.Threads.start_child(session, request["assignment"],
             coding: request["coding"] == true,
             history: request["history"] == true
           ) do
      {:ok, %{"type" => "child_result", "version" => 2, "result" => child}}
    end
  end

  defp run_lifecycle_command(session, "child_list", _request, _provider, _cwd, lifetime) do
    %{children: children, limit: limit} = Elara.Threads.list(session)

    sessions =
      Enum.map(children, fn child ->
        Map.merge(child, %{
          "name" => child["assignment"],
          "model" => get_in(child, ["settings", "model"]) || child["model"]
        })
      end)

    {:ok,
     %{
       "type" => "session_list",
       "version" => 2,
       "sessions" => sessions,
       "child_limit" => limit,
       "lifetime" => Atom.to_string(lifetime)
     }}
  end

  defp run_lifecycle_command(session, command, request, _provider, _cwd, _lifetime)
       when command in ["child_integrate", "child_cleanup", "child_stop_subtree"] do
    result =
      case command do
        "child_integrate" -> Elara.Threads.integrate(session, request["session_id"])
        "child_cleanup" -> Elara.Threads.cleanup(session, request["session_id"])
        "child_stop_subtree" -> Elara.Threads.stop_subtree(session)
      end

    case result do
      :ok ->
        {:ok,
         %{
           "type" => "child_result",
           "version" => 2,
           "result" => "Workspace cleaned; transcript retained"
         }}

      {:ok, value} ->
        {:ok, %{"type" => "child_result", "version" => 2, "result" => value}}

      error ->
        error
    end
  end

  defp run_lifecycle_command(_session, "session_list", _request, _provider, cwd, lifetime) do
    {:ok,
     %{
       "type" => "session_list",
       "version" => 2,
       "sessions" => lifecycle_sessions(cwd),
       "lifetime" => Atom.to_string(lifetime)
     }}
  end

  defp run_lifecycle_command(_session, "session_create", _request, provider, cwd, _lifetime) do
    with {:ok, provider} <- resolve_provider(provider),
         {:ok, id} <- Elara.start_session(provider: provider, cwd: cwd) do
      {:ok, %{"type" => "session_created", "version" => 2, "session_id" => id}}
    end
  end

  defp run_lifecycle_command(
         session,
         "session_name",
         %{"name" => name},
         _provider,
         _cwd,
         _lifetime
       )
       when is_binary(name) and name != "" do
    with true <-
           String.valid?(name) and String.length(name) <= 128 and String.trim(name) != "" and
             not String.contains?(name, ["\n", "\r", "\e"]),
         :ok <- Elara.attached_command(session, {:name, String.trim(name)}) do
      {:ok, session_result("session_name", %{})}
    else
      false -> {:error, :invalid_name}
      error -> error
    end
  end

  defp run_lifecycle_command(_session, "session_name", _request, _provider, _cwd, _lifetime),
    do: {:error, :invalid_name}

  defp run_lifecycle_command(
         session,
         "session_delete",
         %{"session_id" => id},
         _provider,
         cwd,
         _lifetime
       )
       when is_binary(id) do
    with :ok <- reject_current_session(session, id),
         :ok <- delete_session(cwd, id) do
      {:ok, session_result("session_delete", %{"session_id" => id})}
    end
  end

  defp run_lifecycle_command(session, "session_tree", _request, _provider, _cwd, _lifetime) do
    {:ok, %{"type" => "session_tree", "version" => 2, "entries" => Elara.user_entries(session)}}
  end

  defp run_lifecycle_command(
         session,
         "session_fork",
         %{"entry_id" => id},
         _provider,
         _cwd,
         _lifetime
       )
       when is_binary(id) do
    with {:ok, child, prompt} <-
           GenServer.call(session_pid!(session), {:session_fork, id}) do
      response = %{"type" => "session_created", "version" => 2, "session_id" => child}
      {:ok, if(prompt, do: Map.put(response, "prompt", prompt), else: response)}
    end
  end

  defp run_lifecycle_command(session, "session_clone", _request, _provider, _cwd, _lifetime) do
    with {:ok, child, _prompt} <- GenServer.call(session_pid!(session), :session_clone) do
      {:ok, %{"type" => "session_created", "version" => 2, "session_id" => child}}
    end
  end

  defp run_lifecycle_command(session, "session_reload", _request, _provider, _cwd, _lifetime) do
    case Elara.snapshot(session) do
      %{} = snapshot -> {:ok, snapshot_message(snapshot)}
      error -> error
    end
  end

  defp run_lifecycle_command(_session, _command, _request, _provider, _cwd, _lifetime),
    do: {:error, :invalid_command}

  defp delete_session(cwd, id) do
    if Elara.Threads.managed?(id) do
      {:error, :managed_child_use_cleanup_transcript_retained}
    else
      case Elara.session_pid(id) do
        {:ok, pid} -> GenServer.call(pid, {:session_delete, cwd})
        {:error, :session_not_found} -> delete_saved_session(cwd, id)
      end
    end
  end

  defp reject_current_session(session, id) do
    if Elara.session_pid(session) == Elara.session_pid(id),
      do: {:error, :switch_first},
      else: :ok
  end

  defp delete_saved_session(cwd, id) do
    with {:ok, info} <- Elara.Session.Store.find(cwd, id),
         {:ok, store} <- Elara.Session.Store.open(info.path, cwd),
         {:ok, store} <- Elara.Session.Store.claim(store) do
      result = Elara.Session.Store.delete(store)
      Elara.Session.Store.release(store)
      result
    end
  end

  defp session_pid!(session) do
    {:ok, pid} = Elara.session_pid(session)
    pid
  end

  defp session_result(command, extra),
    do: Map.merge(%{"type" => "session_result", "version" => 2, "command" => command}, extra)

  defp session_error(command, reason),
    do: %{
      "type" => "session_error",
      "version" => 2,
      "command" => command,
      "error" => format_reason(reason)
    }

  defp input_command(_session, cwd, "discover_files", request) do
    with {:ok, result} <- Elara.Attachment.discover(cwd, request["query"] || "") do
      {:ok, %{"files" => result.files, "truncated" => result.truncated}}
    end
  end

  defp input_command(_session, _cwd, "ingest_image", request) do
    with {:ok, image} <- Elara.Attachment.ingest_image(request["name"], request["base64"]) do
      images = Process.get(:input_images, %{})

      if map_size(images) < 16 or Map.has_key?(images, image["id"]) do
        Process.put(:input_images, Map.put(images, image["id"], image))
        {:ok, %{"attachment" => Elara.Attachment.metadata(image)}}
      else
        {:error, :image_draft_limit_reconnect_to_clear}
      end
    end
  end

  defp input_command(_session, _cwd, "discard_attachment", request) do
    Process.put(
      :input_images,
      Map.delete(Process.get(:input_images, %{}), request["attachment_id"])
    )

    :ok
  end

  defp input_command(session, _cwd, "ask", request) do
    ids = request["attachment_ids"] || []
    images = Process.get(:input_images, %{})

    if is_list(ids) and length(ids) <= 4 and Enum.all?(ids, &Map.has_key?(images, &1)) do
      Elara.attached_command(
        session,
        {:ask_input, request["prompt"], request["references"] || [], Enum.map(ids, &images[&1])}
      )
    else
      {:error, :unknown_attachment_reselect_image}
    end
  end

  defp queue_command(session, "submit_input", request) do
    kind =
      case request["kind"] do
        "normal" -> :normal
        "steer" -> :steer
        _ -> :invalid
      end

    result =
      with {:ok, cwd} <- Elara.attached_command(session, :input_workspace),
           ids = request["attachment_ids"] || [],
           images = Process.get(:input_images, %{}),
           refs = request["references"] || [],
           true <- is_binary(request["submission_id"]) and is_binary(request["sender_id"]),
           true <- is_binary(request["prompt"]),
           true <- is_list(refs),
           true <- is_list(ids),
           true <- length(ids) <= 4 and Enum.all?(ids, &Map.has_key?(images, &1)),
           true <- kind in [:normal, :steer],
           {:ok, user} <-
             Elara.Attachment.prepare(
               cwd,
               request["prompt"],
               refs,
               Enum.map(ids, &images[&1])
             ) do
        Elara.attached_command(
          session,
          {:submit_input,
           %{
             id: request["submission_id"],
             sender_id: request["sender_id"],
             kind: kind,
             user: user
           }}
        )
      else
        false -> {:error, :invalid_input}
        {:error, reason} -> {:error, reason}
      end

    receipt_result("submit_input", request["submission_id"], result)
  end

  defp queue_command(session, "cancel_input", request),
    do:
      receipt_result(
        "cancel_input",
        request["submission_id"],
        Elara.attached_command(session, {:cancel_input, request["submission_id"]})
      )

  defp queue_command(session, "input_status", request),
    do:
      receipt_result(
        "input_status",
        request["submission_id"],
        Elara.attached_command(session, {:input_status, request["submission_id"]})
      )

  defp queue_command(session, "resume_inputs", request),
    do:
      receipt_result(
        "resume_inputs",
        request["submission_id"],
        Elara.attached_command(session, :resume_inputs)
      )

  defp receipt_result(command, id, {:ok, entry}), do: input_receipt(command, id, entry, nil)
  defp receipt_result(command, id, :ok), do: input_receipt(command, id, nil, nil)
  defp receipt_result(command, id, {:error, reason}), do: input_receipt(command, id, nil, reason)

  defp input_receipt(command, id, entry, error) do
    %{
      "type" => "input_receipt",
      "version" => 2,
      "command" => command,
      "submission_id" => id,
      "entry" => encode_input_entry(entry)
    }
    |> then(fn receipt ->
      if error, do: Map.put(receipt, "error", format_reason(error)), else: receipt
    end)
  end

  defp encode_input_entry(nil), do: nil

  defp encode_input_entry(entry),
    do: %{
      "id" => entry.id,
      "session_id" => entry.session_id,
      "sender_id" => entry.sender_id,
      "kind" => Atom.to_string(entry.kind),
      "state" => Atom.to_string(entry.state),
      "text" => entry.user.text,
      "attachments" => Enum.map(entry.user.attachments, &Elara.Attachment.metadata/1),
      "error" => entry.error
    }

  defp command_result(:ok, version), do: %{"type" => "ok", "version" => version}
  defp command_result({:error, reason}, version), do: error_message(reason, version)

  defp snapshot_message(snapshot) do
    %{
      "type" => "snapshot",
      "version" => 2,
      "session_id" => snapshot.id,
      "incarnation" => snapshot.incarnation,
      "head" => snapshot.head,
      "snapshot" => negotiated_snapshot(snapshot.snapshot)
    }
  end

  defp decode_mode("control"), do: {:ok, :control}
  defp decode_mode("observe"), do: {:ok, :observe}
  defp decode_mode(_mode), do: {:error, :invalid_mode}

  defp decode_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: {:ok, cursor}
  defp decode_cursor(_cursor), do: {:error, :invalid_cursor}

  defp decode_cwd(cwd) when is_binary(cwd), do: {:ok, Path.expand(cwd)}
  defp decode_cwd(_cwd), do: {:error, :invalid_cwd}
  defp decode_optional_cwd(nil), do: {:ok, nil}
  defp decode_optional_cwd(cwd), do: decode_cwd(cwd)

  defp ensure_live_session(id, cwd, provider) do
    case Elara.session_pid(id) do
      {:ok, _pid} ->
        # Explicit live IDs have always been attachable from another cwd.
        # Discovery and saved-file lookup remain scoped to the workspace.
        {:ok, id}

      {:error, :session_not_found} ->
        cwd = cwd || File.cwd!()

        if Elara.Threads.managed?(id) do
          with {:ok, provider} <- resolve_provider(provider),
               do: Elara.Threads.resume(id, provider: provider)
        else
          with {:ok, info} <- Elara.Session.Store.find(cwd, id),
               {:ok, provider} <- resolve_provider(provider),
               {:ok, ^id} <- Elara.start_session(provider: provider, cwd: cwd, resume: info.path) do
            {:ok, id}
          end
        end
    end
  end

  defp resolve_provider(nil), do: Elara.Config.resolve()
  defp resolve_provider(provider), do: {:ok, provider}

  defp response_version(%{"version" => version}) when version in @protocol_versions, do: version
  defp response_version(_request), do: Protocol.version()

  defp send_error(socket, reason, version), do: send_json(socket, error_message(reason, version))

  defp error_message(reason, version) do
    %{"type" => "error", "version" => version, "error" => format_reason(reason)}
  end

  defp format_reason(reason)
       when reason in [
              :codex_not_logged_in,
              :invalid_codex_auth_file,
              :codex_login_refresh_required
            ],
       do: Elara.Config.error_message(reason)

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp send_json(socket, message), do: :gen_tcp.send(socket, Protocol.encode(message))

  defp recv_line(socket, timeout, line_buffer \\ {[], 0}) do
    with {:ok, chunk} <- :gen_tcp.recv(socket, 0, timeout) do
      case Protocol.push_line(line_buffer, chunk) do
        {:ok, line} -> {:ok, line}
        {:more, line_buffer} -> recv_line(socket, timeout, line_buffer)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp json_status(status) do
    %{
      "id" => status.id,
      "incarnation" => status.incarnation,
      "phase" => inspect(status.phase),
      "current_effect" => inspect(status.current_effect),
      "mailbox_length" => status.mailbox_length,
      "task_count" => status.task_count,
      "subscriber_count" => status.subscriber_count,
      "event_head" => status.event_head,
      "event_retained" => status.event_retained,
      "recording_path" => status.recording_path,
      "recorded_transitions" => status.recorded_transitions,
      "worker_health" =>
        Enum.map(status.worker_health, fn worker ->
          %{
            "id" => worker.id,
            "healthy" => worker.healthy?,
            "load" => worker.load,
            "placement" => Atom.to_string(worker.placement)
          }
        end)
    }
  end
end
