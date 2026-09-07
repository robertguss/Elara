defmodule Elara.CheckEvidence do
  @moduledoc "Bounded, immutable excerpts from one completed project check."

  @scope "Selected file excerpts captured before the command; not an atomic workspace snapshot."
  @source_limit 4_096
  @output_limit 8_192

  def record(%Elara.Tool.Ctx{session_id: nil}, _evidence), do: :ok

  def record(%Elara.Tool.Ctx{session_id: id}, evidence) do
    with {:ok, pid} <- Elara.session_pid(id), do: GenServer.call(pid, {:record_check, evidence})
  end

  def fetch(nil, _run_id),
    do: {:error, "No captured check. Run elixir_test or elixir_check with evidence_paths first."}

  def fetch(evidence, run_id) do
    cond do
      not valid?(evidence) ->
        {:error, "Saved check evidence is invalid"}

      run_id != nil and run_id != evidence["id"] ->
        {:error, "Captured check ID does not match; inspect check_evidence again"}

      true ->
        {:ok, evidence}
    end
  end

  def capture(cwd, paths) do
    with {:ok, user} <- Elara.Attachment.prepare(cwd, "", paths, []) do
      {:ok,
       user.attachments
       |> Enum.uniq_by(& &1["name"])
       |> Enum.map(fn item ->
         content = prefix(item["content"], @source_limit)

         artifact(
           item["name"],
           "source",
           content,
           item["clipped"] or byte_size(item["content"]) > @source_limit
         )
       end)}
    end
  end

  def finish(cwd, sources, command, exit_status, duration_ms, output) do
    repaired_output = String.replace_invalid(output)
    log = "Command: #{command}\nExit status: #{exit_status}\n\n" <> repaired_output

    %{
      "version" => 1,
      "id" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "command" => command,
      "exit_status" => exit_status,
      "duration_ms" => duration_ms,
      "output_encoding_repaired" => repaired_output != output,
      "artifacts" => [
        artifact("check output", "log", excerpt(log), byte_size(log) > @output_limit) | sources
      ],
      "source_observations" => Enum.map(sources, &observe_after(cwd, &1)),
      "scope" => @scope
    }
  end

  def valid?(%{"version" => 1, "artifacts" => artifacts} = evidence) when is_list(artifacts) do
    is_binary(evidence["id"]) and byte_size(evidence["id"]) in 1..80 and
      is_binary(evidence["command"]) and byte_size(evidence["command"]) in 1..2_048 and
      is_integer(evidence["exit_status"]) and is_integer(evidence["duration_ms"]) and
      length(artifacts) in 1..5 and Enum.all?(artifacts, &valid_artifact?/1) and
      length(Enum.uniq_by(artifacts, & &1["id"])) == length(artifacts) and
      is_list(evidence["source_observations"]) and evidence["scope"] == @scope and
      byte_size(JSON.encode!(evidence)) <= 131_072
  end

  def valid?(_), do: false

  def lines(artifact), do: String.split(artifact["content"], "\n")

  def prefix(text, limit) when byte_size(text) <= limit, do: text

  def prefix(text, limit) do
    candidate = binary_part(text, 0, limit)
    if String.valid?(candidate), do: candidate, else: prefix(text, limit - 1)
  end

  defp excerpt(text) when byte_size(text) <= @output_limit, do: text

  defp excerpt(text) do
    half = div(@output_limit - 64, 2)

    prefix(text, half) <>
      "\n[... middle of output omitted ...]\n" <>
      (text |> String.reverse() |> prefix(half) |> String.reverse())
  end

  defp artifact(name, kind, content, clipped) do
    %{
      "id" => digest([name, kind, content, clipped]),
      "name" => name,
      "kind" => kind,
      "content" => content,
      "clipped" => clipped
    }
  end

  defp valid_artifact?(%{
         "name" => name,
         "kind" => kind,
         "content" => content,
         "clipped" => clipped,
         "id" => id
       })
       when is_binary(name) and kind in ["source", "log"] and is_binary(content) and
              is_boolean(clipped) do
    byte_size(name) <= 1_024 and byte_size(content) <= @output_limit and String.valid?(content) and
      id == digest([name, kind, content, clipped])
  end

  defp valid_artifact?(_), do: false

  defp observe_after(cwd, source) do
    state =
      case capture(cwd, [source["name"]]) do
        {:ok, [after_source]} ->
          if after_source["id"] == source["id"],
            do: "unchanged_in_captured_excerpt",
            else: "changed"

        {:error, _} ->
          "unavailable"
      end

    %{"path" => source["name"], "state" => state}
  end

  defp digest(value),
    do: :crypto.hash(:sha256, JSON.encode!(value)) |> Base.encode16(case: :lower)
end
