defmodule Elara.Attachment do
  @moduledoc "Explicit bounded inputs. Paths are workspace-relative; image ingestion accepts bytes only."
  @text_limit 65_536
  @image_limit 2_097_152
  @selection_limit 4

  def prepare(cwd, prompt, references, images)
      when is_binary(prompt) and byte_size(prompt) <= 1_048_576 and is_list(references) and
             is_list(images) do
    if length(references) + length(images) <= @selection_limit do
      with {:ok, texts} <- collect(references, &read_text(cwd, &1)),
           true <- Enum.all?(images, &valid_owned_image?/1) do
        user = %Elara.Message.User{text: prompt, attachments: texts ++ images}

        if byte_size(JSON.encode!(Elara.Session.Store.encode_message(user))) <= 15 * 1_024 * 1_024,
          do: {:ok, user},
          else: {:error, :input_too_large}
      else
        false -> {:error, :invalid_attachment}
        error -> error
      end
    else
      {:error, :too_many_attachments}
    end
  end

  def prepare(_, prompt, _, _) when is_binary(prompt) and byte_size(prompt) > 1_048_576,
    do: {:error, :input_too_large}

  def prepare(_, _, _, _), do: {:error, :invalid_attachment}

  def valid_persisted?(attachments) when is_list(attachments) and length(attachments) <= 4,
    do: Enum.all?(attachments, &valid_persisted_item?/1)

  def valid_persisted?(_), do: false

  defp valid_persisted_item?(
         %{
           "kind" => "text",
           "name" => name,
           "content" => content,
           "bytes" => bytes,
           "included_bytes" => included,
           "clipped" => clipped,
           "source" => "workspace",
           "id" => id
         } = item
       )
       when is_binary(name) and is_binary(content) and is_integer(bytes) and is_boolean(clipped) do
    map_size(item) == 8 and byte_size(content) <= @text_limit and String.valid?(content) and
      not String.contains?(content, <<0>>) and included == byte_size(content) and
      bytes >= included and
      id == digest(JSON.encode!([name, bytes, clipped, content]))
  end

  defp valid_persisted_item?(item), do: valid_owned_image?(item)

  def metadata(attachment), do: Map.drop(attachment, ["content", "base64"])

  def provider_text(%Elara.Message.User{text: text, attachments: attachments}) do
    Enum.reduce(attachments, text, fn
      %{"kind" => "text", "name" => name, "content" => content, "clipped" => clipped}, acc ->
        label = if clipped, do: "clipped to #{@text_limit} bytes", else: "complete"
        acc <> "\n\n[Selected file: #{name}; #{label}]\n" <> content <> "\n[End selected file]"

      _, acc ->
        acc
    end)
  end

  def ingest_image(name, encoded) when is_binary(name) and is_binary(encoded) do
    with true <- byte_size(name) in 1..1024 and String.valid?(name),
         true <- byte_size(encoded) <= 4 * div(@image_limit + 2, 3),
         {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) <= @image_limit,
         {:ok, width, height} <- validate_png(bytes) do
      basename = Path.basename(name)

      {:ok,
       %{
         "id" => digest(basename <> <<0>> <> bytes),
         "kind" => "image",
         "name" => basename,
         "mime_type" => "image/png",
         "bytes" => byte_size(bytes),
         "width" => width,
         "height" => height,
         "base64" => Base.encode64(bytes)
       }}
    else
      _ -> {:error, :invalid_or_oversize_png}
    end
  end

  def ingest_image(_, _), do: {:error, :invalid_or_oversize_png}

  def discover(cwd, query) when is_binary(query) and byte_size(query) <= 1024 do
    task =
      Task.Supervisor.async_nolink(Elara.TaskSup, fn ->
        Process.flag(:max_heap_size, %{size: 1_000_000, kill: true, error_logger: false})

        prefix = discovery_prefix(cwd, query)

        case File.ls(Path.join(cwd, prefix)) do
          {:ok, names} ->
            limited = names |> Enum.take(5000) |> Enum.sort() |> Enum.map(&Path.join(prefix, &1))
            {files, truncated} = walk(cwd, limited, query, [], 0, length(names) > 5000)
            {:ok, %{files: Enum.reverse(files), truncated: truncated}}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case Task.yield(task, 250) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :discovery_limit_try_narrower_directory}
    end
  end

  def discover(_, _), do: {:error, :invalid_query}

  defp discovery_prefix(cwd, query) do
    prefix = query |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")

    case scoped_path(cwd, prefix) do
      {:ok, path} -> if File.dir?(path), do: prefix, else: ""
      _ -> ""
    end
  end

  defp walk(_, _, _, files, n, _) when n >= 5000 or length(files) >= 50, do: {files, true}
  defp walk(_, [], _, files, _, truncated), do: {files, truncated}

  defp walk(cwd, [path | rest], query, files, n, truncated) do
    full = Path.join(cwd, path)

    case File.lstat(full) do
      {:ok, %{type: :directory}} ->
        budget = max(0, 5000 - n - length(rest) - 1)

        {children, clipped} =
          if Path.basename(path) in [".git", "_build", "deps", "node_modules", "target"] do
            {[], false}
          else
            case File.ls(full) do
              {:ok, names} ->
                {names |> Enum.take(budget) |> Enum.sort() |> Enum.map(&Path.join(path, &1)),
                 length(names) > budget}

              _ ->
                {[], false}
            end
          end

        walk(cwd, rest ++ children, query, files, n + 1, truncated or clipped)

      {:ok, %{type: :regular, size: bytes}} ->
        files = if fuzzy?(path, query), do: [%{path: path, bytes: bytes} | files], else: files
        walk(cwd, rest, query, files, n + 1, truncated)

      _ ->
        walk(cwd, rest, query, files, n + 1, truncated)
    end
  end

  defp fuzzy?(path, query) do
    Enum.reduce(
      String.graphemes(String.downcase(path)),
      String.graphemes(String.downcase(query)),
      fn
        char, [char | rest] -> rest
        _, remaining -> remaining
      end
    ) == []
  end

  defp read_text(cwd, path) when is_binary(path) and byte_size(path) <= 4096 do
    task = Task.Supervisor.async_nolink(Elara.TaskSup, fn -> read_text_input(cwd, path) end)

    case Task.yield(task, 500) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :file_read_timeout_retry}
    end
  end

  defp read_text(_, _), do: {:error, :invalid_path}

  defp read_text_input(cwd, path) do
    with {:ok, full} <- scoped_path(cwd, path),
         {:ok, %{type: :regular}} <- File.lstat(full),
         {:ok, size, data} <- read_regular_file(cwd, full) do
      clipped = byte_size(data) > @text_limit
      data = binary_part(data, 0, min(byte_size(data), @text_limit))
      data = if clipped, do: trim_utf8(data, 3), else: data

      if String.valid?(data) and not String.contains?(data, <<0>>) do
        {:ok,
         %{
           "id" => digest(JSON.encode!([path, size, clipped, data])),
           "kind" => "text",
           "name" => path,
           "source" => "workspace",
           "bytes" => size,
           "included_bytes" => byte_size(data),
           "clipped" => clipped,
           "content" => data
         }}
      else
        {:error, :not_utf8_text}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_file}
    end
  end

  # A BEAM file open can block a dirty-I/O scheduler forever if a checked path
  # becomes a FIFO. The managed native helper uses nonblocking open and fstat;
  # its guardian kills/reaps it on timeout or when this task dies.
  defp read_regular_file(cwd, path) do
    helper = Application.app_dir(:elara, "priv/native/exec-stub")

    case Elara.Exec.run([helper, "--read-attachment", path],
           cwd: cwd,
           max_bytes: @text_limit + 9,
           timeout_ms: 250
         ) do
      {:ok, %{termination: :exited, code: 0, output: <<size::64, data::binary>>}} ->
        {:ok, size, data}

      {:ok, %{termination: :timed_out}} ->
        {:error, :file_read_timeout_retry}

      _ ->
        {:error, :invalid_file}
    end
  end

  defp scoped_path(cwd, path) do
    parts = Path.split(path)

    if Path.type(path) == :relative and parts != [] and not Enum.any?(parts, &(&1 in ["..", "."])) do
      Enum.reduce_while(parts, {:ok, Path.expand(cwd)}, fn part, {:ok, parent} ->
        full = Path.join(parent, part)

        case File.lstat(full) do
          {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink_not_allowed}}
          {:ok, _} -> {:cont, {:ok, full}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :outside_workspace}
    end
  end

  defp trim_utf8(data, left) do
    if String.valid?(data) or left == 0 or data == "",
      do: data,
      else: trim_utf8(binary_part(data, 0, byte_size(data) - 1), left - 1)
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp valid_owned_image?(%{"kind" => "image", "base64" => encoded, "name" => name} = image) do
    case ingest_image(name, encoded) do
      {:ok, validated} -> validated == image
      _ -> false
    end
  end

  defp valid_owned_image?(_), do: false

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, item} -> {:cont, {:ok, acc ++ [item]}}
        error -> {:halt, error}
      end
    end)
  end

  # Deliberately supports only 8-bit, non-interlaced grayscale/RGB/gray-alpha/RGBA PNG.
  # CRCs, zlib stream and every scanline are decoded/checked with bounded output.
  defp validate_png(<<137, 80, 78, 71, 13, 10, 26, 10, rest::binary>>) do
    with {:ok, chunks} <- png_chunks(rest, []),
         [{"IHDR", <<w::32, h::32, 8, color, 0, 0, 0>>} | body] <- chunks,
         true <- w in 1..4096 and h in 1..4096 and w * h <= 16_000_000,
         channels when is_integer(channels) <- %{0 => 1, 2 => 3, 4 => 2, 6 => 4}[color],
         true <- List.last(body) == {"IEND", ""},
         true <- Enum.count(body, fn {type, _} -> type == "IEND" end) == 1,
         true <- consecutive_data?(body),
         true <-
           Enum.all?(body, fn {type, _} ->
             type in [
               "IDAT",
               "IEND",
               "tEXt",
               "iTXt",
               "zTXt",
               "gAMA",
               "sRGB",
               "pHYs",
               "cHRM",
               "bKGD",
               "tRNS"
             ]
           end),
         compressed <- for({"IDAT", data} <- body, into: "", do: data),
         {:ok, decoded} <- inflate(compressed, h * (1 + w * channels)),
         true <- scanlines?(decoded, 1 + w * channels, h) do
      {:ok, w, h}
    else
      _ -> {:error, :invalid_png}
    end
  end

  defp validate_png(_), do: {:error, :invalid_png}

  defp consecutive_data?(body) do
    data_and_tail = Enum.drop_while(body, fn {type, _} -> type != "IDAT" end)
    {data, tail} = Enum.split_while(data_and_tail, fn {type, _} -> type == "IDAT" end)
    data != [] and not Enum.any?(tail, fn {type, _} -> type == "IDAT" end)
  end

  defp png_chunks("", acc), do: {:ok, Enum.reverse(acc)}

  defp png_chunks(
         <<n::32, type::binary-size(4), data::binary-size(n), crc::32, rest::binary>>,
         acc
       ) do
    if length(acc) < 1024 and :erlang.crc32(type <> data) == crc,
      do: png_chunks(rest, [{type, data} | acc]),
      else: {:error, :invalid_png}
  end

  defp png_chunks(_, _), do: {:error, :invalid_png}

  defp inflate(compressed, expected) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      result = inflate_parts(z, compressed, expected, [])
      :ok = :zlib.inflateEnd(z)
      result
    catch
      _, _ -> {:error, :invalid_png}
    after
      :zlib.close(z)
    end
  end

  defp inflate_parts(z, bytes, remaining, acc) do
    {status, output} = :zlib.safeInflate(z, bytes)
    size = IO.iodata_length(output)

    cond do
      size > remaining ->
        {:error, :invalid_png}

      status == :finished and size == remaining ->
        {:ok, IO.iodata_to_binary(Enum.reverse([output | acc]))}

      status == :finished ->
        {:error, :invalid_png}

      true ->
        inflate_parts(z, <<>>, remaining - size, [output | acc])
    end
  end

  defp scanlines?("", _, 0), do: true

  defp scanlines?(data, width, rows) when rows > 0 and byte_size(data) >= width do
    <<filter, _pixels::binary-size(^width - 1), rest::binary>> = data
    filter <= 4 and scanlines?(rest, width, rows - 1)
  end

  defp scanlines?(_, _, _), do: false
end
