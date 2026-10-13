defmodule Elara.Output do
  @moduledoc "Session-owned immutable output and bounded retrieval, not a query engine."

  alias Elara.{Exec, Message, Tool}
  alias Elara.Session.Store

  @cap 128 * 1024 * 1024
  @envelope ~r/\A\[output (out_[A-Za-z0-9_-]{43});/
  @handle ~r/\Aout_[A-Za-z0-9_-]{43}\z/
  @session ~r/\A[A-Za-z0-9_-]{1,128}\z/
  @type source :: {:command, [String.t()], keyword()} | {:content, atom(), Enumerable.t()}
  @type selector ::
          {:range, pos_integer(), pos_integer()}
          | {:literal, String.t(), pos_integer(), pos_integer()}

  @spec capture(Tool.Ctx.t(), source()) :: Tool.outcome()
  def capture(%Tool.Ctx{} = ctx, source) do
    with {:ok, vault} <- vault(ctx.output_owner || ctx.session_id),
         :ok <- preview_budget(ctx),
         :ok <- File.mkdir_p(vault),
         :ok <- File.chmod(vault, 0o700) do
      handle = "out_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      path = Path.join(vault, handle <> ".part")

      case capture_source(source, ctx, path) do
        {:captured, kind, note} -> publish(ctx, vault, handle, path, kind, note)
        outcome -> outcome
      end
    else
      {:error, reason} -> {:error, "output capture refused before execution: #{inspect(reason)}"}
    end
  end

  @spec read(Tool.Ctx.t(), String.t(), selector()) :: Tool.outcome()
  def read(%Tool.Ctx{} = ctx, handle, selector) do
    with :ok <- preview_budget(ctx),
         :ok <- validate_selector(selector),
         {:ok, path, metadata} <- object(ctx.output_owner || ctx.session_id, handle) do
      {offset, limit, pattern} =
        case selector do
          {:range, offset, limit} -> {offset, limit, nil}
          {:literal, pattern, offset, limit} -> {offset, limit, pattern}
        end

      budget = budget(ctx) - 512

      initial = %{
        line: 1,
        prefix: "",
        carry: "",
        found: false,
        line_bytes: 0,
        snippet: nil,
        nonempty: false,
        rows: [],
        count: 0,
        bytes: 0,
        stopped: false
      }

      result =
        path
        |> File.stream!(8192)
        |> Enum.reduce_while(initial, fn chunk, state ->
          state = scan(chunk, state, offset, limit, pattern, budget)
          if state.stopped, do: {:halt, state}, else: {:cont, state}
        end)

      result =
        if result.nonempty and not result.stopped,
          do: finish_line(result, offset, limit, pattern, budget),
          else: result

      rows = result.rows |> Enum.reverse() |> Enum.join("\n")

      suffix =
        if result.stopped and result.line <= metadata["lines"],
          do:
            "\n[more: output_read offset=#{result.line} limit=#{limit}#{if pattern, do: "; keep the same literal pattern", else: ""}]",
          else: "\n[end of output]"

      {:ok,
       "[output #{handle}; bytes=#{metadata["bytes"]}; lines=#{metadata["lines"]}]\n" <>
         rows <> suffix}
    else
      {:error, reason} -> {:error, "output_read refused: #{inspect(reason)}"}
    end
  rescue
    _error in File.Error -> {:error, "retained output unavailable"}
  end

  @doc "Install only handles in trusted copied tool evidence before publishing its new history."
  @spec inherit(String.t(), String.t(), [Message.t()]) :: :ok | {:error, term()}
  def inherit(source, target, messages) do
    handles =
      messages
      |> Enum.flat_map(fn
        %Message.ToolResult{outcome: {_, text}} when is_binary(text) ->
          case Regex.run(@envelope, text) do
            [_, handle] -> [handle]
            _ -> []
          end

        _ ->
          []
      end)
      |> Enum.uniq()

    with {:ok, target_vault} <- vault(target),
         :ok <- File.mkdir_p(target_vault),
         :ok <- File.chmod(target_vault, 0o700) do
      Enum.reduce_while(handles, :ok, fn handle, :ok ->
        with {:ok, path, metadata} <- object(source, handle),
             :ok <- install(path, Path.join(target_vault, handle <> ".bytes")),
             :ok <- write_metadata(Path.join(target_vault, handle <> ".json"), metadata) do
          {:cont, :ok}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp capture_source({:command, argv, opts}, ctx, path) do
    opts =
      Keyword.merge(opts,
        cwd: ctx.cwd,
        timeout_ms: ctx.timeout_ms || 600_000,
        output_policy: :head_tail,
        max_bytes: budget(ctx),
        capture: %{"path" => path, "max_bytes" => @cap}
      )

    case Exec.run(argv, opts) do
      {:ok, %Exec.Result{capture_limited: true}} ->
        {:captured, :indeterminate,
         "stopped and reaped at the 128 MiB retained-output cap; " <>
           "retained prefix only; the command may have partially changed the workspace"}

      {:ok, %Exec.Result{termination: :exited, code: 0}} ->
        {:captured, :ok, ""}

      {:ok, %Exec.Result{termination: :exited, code: code}} when is_integer(code) ->
        {:captured, :error, "exit #{code}"}

      {:ok, %Exec.Result{termination: :exited, signal: signal}} ->
        {:captured, :error, "signal #{signal}"}

      {:ok, %Exec.Result{termination: termination}} ->
        reason = if termination == :timed_out, do: "timed out", else: Atom.to_string(termination)

        {:captured, :indeterminate,
         "#{reason} while running; retained output is partial; it may have partially changed the workspace; " <>
           "inspect the workspace before rerunning with a longer timeout_ms up to the configured ceiling"}

      {:error, {:not_started, message}} ->
        {:error, "execution failed: #{message}"}

      {:indeterminate, message} ->
        {:indeterminate, "output capture/execution failed: #{message}; effects may be partial"}
    end
  end

  defp capture_source({:content, kind, chunks}, _ctx, path)
       when kind in [:ok, :error, :indeterminate] do
    case File.open(path, [:write, :binary, :exclusive], fn io ->
           :ok = File.chmod(path, 0o600)

           result =
             Enum.reduce_while(chunks, 0, fn chunk, size ->
               if not is_binary(chunk), do: raise(ArgumentError, "output chunks must be binaries")
               kept = min(byte_size(chunk), @cap - size)
               :ok = IO.binwrite(io, binary_part(chunk, 0, kept))
               if size + kept == @cap, do: {:halt, :limited}, else: {:cont, size + kept}
             end)

           :ok = :file.sync(io)
           result
         end) do
      {:ok, :limited} -> {:captured, :indeterminate, "128 MiB cap reached; retained prefix only"}
      {:ok, _size} -> {:captured, kind, ""}
      {:error, reason} -> {:error, "output capture failed: #{inspect(reason)}"}
    end
  rescue
    error -> {:indeterminate, "output capture failed: #{Exception.message(error)}"}
  end

  defp publish(ctx, vault, handle, part, kind, note) do
    {bytes, newlines, last} =
      File.stream!(part, 8192)
      |> Enum.reduce({0, 0, nil}, fn chunk, {n, lines, _} ->
        {n + byte_size(chunk), lines + length(:binary.matches(chunk, "\n")), :binary.last(chunk)}
      end)

    lines = newlines + if(bytes > 0 and last != 10, do: 1, else: 0)
    complete = kind != :indeterminate

    metadata = %{
      "bytes" => bytes,
      "lines" => lines,
      "capture" => if(complete, do: "complete", else: "partial")
    }

    header =
      "[output #{handle}; bytes=#{bytes}; lines=#{lines}; capture=#{metadata["capture"]}]\n" <>
        "#{note}\nUse output_read with this handle, offset/limit (lines), or literal pattern.\n"

    remaining = budget(ctx) - byte_size(header) - 64
    head_limit = div(remaining * 3, 8)
    tail_limit = remaining - head_limit

    {:ok, {head, tail, clipped}} =
      File.open(part, [:read, :binary], fn io ->
        whole = if bytes <= remaining, do: pread(io, 0, bytes) |> String.replace_invalid()

        if whole && byte_size(whole) <= remaining do
          {whole, "", false}
        else
          head = pread(io, 0, min(bytes, head_limit)) |> display(head_limit)

          tail =
            pread(
              io,
              max(head_limit, bytes - tail_limit),
              min(max(bytes - head_limit, 0), tail_limit)
            )
            |> display(tail_limit, :tail)

          {head, tail, true}
        end
      end)

    text =
      if clipped,
        do: header <> "[head]\n" <> head <> "\n[omitted middle]\n[tail]\n" <> tail,
        else: header <> head

    with :ok <- File.chmod(part, 0o400),
         :ok <- File.rename(part, Path.join(vault, handle <> ".bytes")),
         :ok <- write_metadata(Path.join(vault, handle <> ".json"), metadata) do
      {kind, text}
    else
      {:error, reason} ->
        {:indeterminate, "output publication failed: #{inspect(reason)}; effects may be partial"}
    end
  rescue
    error ->
      {:indeterminate,
       "output publication failed: #{Exception.message(error)}; effects may be partial"}
  end

  defp scan(chunk, state, offset, limit, pattern, budget) do
    case :binary.split(chunk, "\n") do
      [bytes] ->
        add_bytes(state, bytes, pattern, budget)

      [bytes, rest] ->
        state =
          state
          |> add_bytes(bytes, pattern, budget)
          |> finish_line(offset, limit, pattern, budget)

        if state.stopped, do: state, else: scan(rest, state, offset, limit, pattern, budget)
    end
  end

  defp add_bytes(state, bytes, pattern, budget) do
    candidate = state.carry <> bytes
    match = if pattern, do: :binary.match(candidate, pattern), else: :nomatch
    found = state.found or match != :nomatch

    snippet =
      case {state.snippet, match} do
        {nil, {position, _}} ->
          start = max(position - 80, 0)

          {state.line_bytes - byte_size(state.carry) + start,
           binary_part(candidate, start, min(byte_size(candidate) - start, budget))}

        _ ->
          state.snippet
      end

    carry =
      if pattern do
        n = min(byte_size(candidate), byte_size(pattern))
        binary_part(candidate, byte_size(candidate) - n, n)
      else
        ""
      end

    room = max(budget - byte_size(state.prefix), 0)

    %{
      state
      | prefix: state.prefix <> binary_part(bytes, 0, min(room, byte_size(bytes))),
        carry: carry,
        found: found,
        line_bytes: state.line_bytes + byte_size(bytes),
        snippet: snippet,
        nonempty: state.nonempty or byte_size(bytes) > 0
    }
  end

  defp finish_line(state, offset, limit, pattern, budget) do
    selected = state.line >= offset and (is_nil(pattern) or state.found)

    {prefix, label} =
      case state.snippet do
        {position, snippet} when state.line_bytes > byte_size(state.prefix) ->
          {snippet, "#{state.line} [matching snippet at byte #{position}]: "}

        _ ->
          {state.prefix, "#{state.line}: "}
      end

    room = max(budget - state.bytes - byte_size(label) - 64, 0)
    displayed = display(prefix, room)
    clipped = state.line_bytes > byte_size(prefix) or byte_size(displayed) < byte_size(prefix)
    row = label <> displayed <> if(clipped, do: " [line clipped]", else: "")

    if selected and state.count > 0 and byte_size(displayed) < byte_size(prefix) do
      %{state | stopped: true}
    else
      state =
        if selected,
          do: %{
            state
            | rows: [row | state.rows],
              count: state.count + 1,
              bytes: state.bytes + byte_size(row) + 1
          },
          else: state

      %{
        state
        | line: state.line + 1,
          prefix: "",
          carry: "",
          found: false,
          line_bytes: 0,
          snippet: nil,
          nonempty: false,
          stopped: state.count >= limit or state.bytes >= budget - 128
      }
    end
  end

  defp object(session, handle) do
    with true <- is_binary(handle) and Regex.match?(@handle, handle),
         {:ok, vault} <- vault(session),
         path = Path.join(vault, handle <> ".bytes"),
         {:ok, %{type: :regular, size: bytes}} <- File.lstat(path),
         true <- bytes <= @cap,
         meta_path = Path.join(vault, handle <> ".json"),
         {:ok, %{type: :regular, size: size}} when size < 1024 <- File.lstat(meta_path),
         {:ok, json} <- File.read(meta_path),
         {:ok, %{"bytes" => ^bytes, "lines" => lines} = metadata} <- JSON.decode(json),
         true <- is_integer(lines) and lines >= 0 do
      {:ok, path, metadata}
    else
      _ -> {:error, :unknown_or_unauthorized_handle}
    end
  end

  defp vault(session) do
    with true <- is_binary(session) and Regex.match?(@session, session),
         {:ok, root} <- Store.root(),
         do: {:ok, Path.join([root, "outputs", session])},
         else: (_ -> {:error, :session_required})
  end

  defp install(source, target) do
    case File.ln(source, target) do
      :ok ->
        :ok

      {:error, :eexist} ->
        with {:ok, %{type: :regular, size: size}} <- File.lstat(target),
             {:ok, %{size: ^size}} <- File.stat(source),
             true <- digest(source) == digest(target) do
          :ok
        else
          _ -> {:error, :output_conflict}
        end

      {:error, :exdev} ->
        case File.open(target, [:write, :binary, :exclusive], fn io ->
               :ok = File.chmod(target, 0o600)
               Enum.each(File.stream!(source, 8192), fn chunk -> :ok = IO.binwrite(io, chunk) end)
               :ok = :file.sync(io)
             end) do
          {:ok, :ok} -> File.chmod(target, 0o400)
          {:error, _} = error -> error
        end

      error ->
        error
    end
  end

  defp write_metadata(path, metadata) do
    case File.open(path, [:write, :binary, :exclusive], fn io ->
           :ok = File.chmod(path, 0o600)
           :ok = IO.binwrite(io, JSON.encode!(metadata))
           :ok = :file.sync(io)
         end) do
      {:ok, :ok} ->
        File.chmod(path, 0o400)

      {:error, :eexist} ->
        with {:ok, %{type: :regular, size: size}} when size < 1024 <- File.lstat(path),
             {:ok, text} <- File.read(path),
             true <- text == JSON.encode!(metadata) do
          :ok
        else
          _ -> {:error, :output_conflict}
        end

      {:error, _} = error ->
        error
    end
  end

  defp validate_selector({:range, offset, limit}), do: range(offset, limit)

  defp validate_selector({:literal, pattern, offset, limit}) do
    if is_binary(pattern) and byte_size(pattern) in 1..4096 and String.valid?(pattern),
      do: range(offset, limit),
      else: {:error, :invalid_literal_pattern}
  end

  defp validate_selector(_), do: {:error, :invalid_selector}

  defp range(offset, limit) do
    if is_integer(offset) and offset > 0 and is_integer(limit) and limit in 1..200,
      do: :ok,
      else: {:error, :invalid_line_range}
  end

  defp preview_budget(ctx),
    do: if(budget(ctx) >= 1024, do: :ok, else: {:error, :preview_budget_too_small})

  defp budget(ctx), do: min(ctx.max_output_bytes || 16_384, 16_384)

  defp digest(path) do
    path
    |> File.stream!(8192)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
  end

  defp pread(_io, _offset, 0), do: ""

  defp pread(io, offset, bytes) do
    case :file.pread(io, offset, bytes) do
      {:ok, text} -> text
      :eof -> ""
    end
  end

  defp display(bytes, max, edge \\ :head) do
    text = String.replace_invalid(bytes)

    if byte_size(text) <= max do
      text
    else
      if edge == :tail, do: utf8_suffix(text, max), else: utf8_prefix(text, max)
    end
  end

  defp utf8_prefix(_text, max) when max <= 0, do: ""

  defp utf8_prefix(text, max) do
    kept = binary_part(text, 0, max)
    if String.valid?(kept), do: kept, else: utf8_prefix(text, max - 1)
  end

  defp utf8_suffix(_text, max) when max <= 0, do: ""

  defp utf8_suffix(text, max) do
    kept = binary_part(text, byte_size(text) - max, max)
    if String.valid?(kept), do: kept, else: utf8_suffix(text, max - 1)
  end
end
